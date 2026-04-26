class_name NetworkOrchestrator
extends Node
## Main autoload singleton for the Rollback Netcode Plugin
## (registered as "Netcode").
##
## This is the entry point for the rollback netcode plugin. It manages and
## provides access to core networking subsystems:
##
## - **connector** (NetworkConnector): ENet peer management and connection
##   lifecycle
## - **frame_driver** (FrameDriver): Frame-synchronous simulation and rollback
##   coordination
## - **frame_sync** (FrameSynchronizer): NTP-like frame index synchronization
##   to prevent client/server drift
##
## NetworkOrchestrator determines the local machine's role (server vs client)
## based on command-line arguments or headless mode and provides convenient
## accessors for common networking state:
##
## - is_server / is_client: Current machine's role
## - is_connected_to_server: Connection status (always true on server)
## - local_peer_id: Local multiplayer peer ID
## - server_frame_index: Current server frame number
##
## Usage:
## ```gdscript
## func _ready():
##     Netcode.settings = load("res://network_settings.tres")
##     Netcode.log = MyGameLogger.new()
##     Netcode.initialize()
##
##     if "--server" in OS.get_cmdline_args():
##         Netcode.server_start()
##     else:
##         Netcode.client_connect("127.0.0.1", 4433)
## ```
##
## Testing with multiple instances in Godot editor:
## - In order to support local testing with preview mode in the Godot
##   editor, do the following:
##   - Open Debug > Customize Run Instances.
##   - Check "Enable Multiple Instances".
##   - Set the number of instances to 3.
##   - Check "Override Main Run Args" for each row.
##   - Change the "Launch Arguments" of each row to be one of the following:
##     --server, --client=1, --client=2.
##   - Also, include --preview as an arg in each row.

## Get plugin version from plugin.cfg (single source of truth).
static func get_version() -> String:
	var config := ConfigFile.new()
	var err := config.load("res://addons/rollback_netcode/plugin.cfg")
	if err != OK:
		push_error("Failed to load plugin.cfg for version")
		return "unknown"
	return config.get_value("plugin", "version", "unknown")

# --- Signals ---

## Emitted when a player input node gains multiplayer authority.
signal local_authority_added(node: ReconcilableState)

## Emitted when a player input node loses multiplayer authority.
signal local_authority_removed(node: ReconcilableState)

# --- Configuration (set by consumer before calling initialize()) ---

## Network configuration resource (must be set before initialize()).
var settings: NetworkSettings

## Logging implementation (must be set before initialize()).
var log: NetworkLogger

## Timer utilities for timeouts, intervals, and throttling (created
## automatically during initialize()).
var time: TimeUtils

## Process sentinel for deterministic frame ordering.
var process_sentinel: ProcessSentinel

# --- Core Components ---

## ENet peer management and connection lifecycle.
var connector: NetworkConnector

## Frame-synchronous simulation (will be FrameDriver after Week 5-6 refactor).
var frame_driver: FrameDriver

## NTP-like frame index synchronization.
var frame_sync: FrameSynchronizer

## Optional performance tracker for metrics and monitoring.
var perf_tracker: PerfTracker

## Bundles per-frame state into single packets (WebRTC
## only). Reduces SCTP packet count from ~12/tick to 1.
var state_bundler: StateBundler

## Network condition simulator (debug builds only).
var condition_simulator: NetworkConditionSimulator

var is_debug := true
var is_preview := true
var is_headless := true
var is_server := true

## True when per-frame state is bundled into single
## packets instead of using MultiplayerSynchronizer.
## Only active for WebRTC transport.
var is_bundled_send: bool:
	get:
		return (
			state_bundler != null
			and settings != null
			and settings.transport_type
				== NetworkSettings.TransportType.WEBRTC
		)
var is_client: bool:
	get:
		return not is_server
## True when the process should run server-side
## game logic. This is the case on dedicated
## servers and in local (offline) mode.
var runs_server_logic: bool:
	get:
		return is_server or is_local_mode
## True when the client is running in offline
## local-only mode (same process acts as both
## server and client).
var is_local_mode := false
## If in preview mode, this is only the first client.
## If in published mode, this is any client.
var is_primary_client: bool:
	get:
		if is_server:
			return false
		elif is_preview:
			return preview_client_number == 1
		return true
var preview_client_number := 0

var should_connect_to_remote_server: bool:
	get:
		if settings == null:
			return false
		return not is_preview or settings.preview_connect_to_remote_server

## Server port to bind to.
## Cached from --port command-line argument if present, otherwise uses settings.
var server_port: int


var is_connected_to_server: bool:
	get:
		if connector == null:
			return false
		return connector.is_connected_to_server

var local_peer_id: int:
	get:
		if not is_connected_to_server:
			return 0
		var peer := multiplayer.multiplayer_peer
		if (peer == null
				or peer.get_connection_status()
					== MultiplayerPeer
						.CONNECTION_DISCONNECTED):
			return 0
		return multiplayer.get_unique_id()

## Current server frame index; the primary synchronization primitive.
var server_frame_index: int:
	get:
		if frame_driver == null:
			return 0
		return frame_driver.server_frame_index

var _is_initialized := false


func _enter_tree() -> void:
	# Parse command-line args to determine role and preview mode.
	var args := _parse_cmdline_args()
	is_headless = DisplayServer.get_name() == "headless"
	is_preview = OS.has_feature("editor")
	is_debug = OS.is_debug_build() or is_preview
	preview_client_number = int(args.client) if args.has("client") else 0

	# Determine server/client role based on context.
	if is_preview:
		# Preview mode (editor): Default to server unless --client specified.
		is_server = not args.has("client")
	else:
		# Published mode: Default to client unless --server or headless.
		is_server = is_headless or args.has("server")


## Initialize the networking system.
## Must be called after setting settings and log.
## TimeUtils is created automatically during initialization.
func initialize() -> void:
	if _is_initialized:
		if log != null:
			log.warning(
				"Netcode already initialized",
				NetworkLogger.CATEGORY_CORE_SYSTEMS
			)
		return

	if settings == null:
		push_error("settings must be set before initialize()")
		return

	if log == null:
		push_error("log must be set before initialize()")
		return

	_is_initialized = true

	var args := _parse_cmdline_args()

	# Cache server port from command-line arg or settings.
	server_port = int(args.port) if args.has("port") else settings.server_port

	# Auto-select WebRTC transport for web exports.
	# WebRTC DataChannels provide UDP-like semantics
	# in the browser, eliminating TCP head-of-line
	# blocking that plagues WebSocket.
	if OS.has_feature("web"):
		settings.transport_type = (
			NetworkSettings.TransportType.WEBRTC)

	# Validate preview client number if explicitly specified.
	if is_preview and args.has("client"):
		log.check(
			preview_client_number > 0,
			"Preview client arg must specify number > 0 (e.g., --client=1)"
		)

	time = TimeUtils.new(get_tree())

	process_sentinel = ProcessSentinel.new()
	process_sentinel.name = "ProcessSentinel"
	add_child(process_sentinel)

	connector = NetworkConnector.new()
	connector.name = "NetworkConnector"
	add_child(connector)

	frame_driver = FrameDriver.new()
	frame_driver.name = "FrameDriver"
	add_child(frame_driver)

	frame_sync = FrameSynchronizer.new()
	frame_sync.name = "FrameSynchronizer"
	add_child(frame_sync)

	state_bundler = StateBundler.new()
	state_bundler.name = "StateBundler"
	add_child(state_bundler)

	perf_tracker = PerfTracker.new()
	perf_tracker.name = "PerfTracker"
	add_child(perf_tracker)

	if is_debug:
		condition_simulator = NetworkConditionSimulator.new()
		condition_simulator.name = "NetworkConditionSimulator"
		add_child(condition_simulator)

	if is_server and should_connect_to_remote_server:
		log.check(
			server_port > 0,
			"Server port command-line argument not provided"
		)


## Parses command-line arguments into a dictionary.
## Supports --key=value and --flag formats.
func _parse_cmdline_args() -> Dictionary:
	var result := {}
	var cmdline_args := OS.get_cmdline_args()
	for arg in cmdline_args:
		if arg.begins_with("--"):
			var key_value := arg.substr(2).split("=", true, 1)
			if key_value.size() == 2:
				result[key_value[0]] = key_value[1]
			else:
				result[key_value[0]] = true
	return result


# This is duplicated here for convenience when accessing.
func get_peer_id_from_player_id(p_player_id: int) -> int:
	return connector.get_peer_id_from_player_id(p_player_id)


# This is duplicated here for convenience when accessing.
func get_local_player_index_from_player_id(p_player_id: int) -> int:
	return connector.get_local_player_index_from_player_id(p_player_id)


## Apply the WebRTC physics tick rate if the
## current transport is WebRTC and a rate override
## is configured. Call when a match starts.
## Apply the WebRTC physics tick rate if the
## current transport is WebRTC and a rate override
## is configured. Called when a match starts
## (server: game session, client: matchmaking
## response, preview: countdown).
func apply_match_physics_fps() -> void:
	if (
		settings.transport_type
			!= NetworkSettings.TransportType.WEBRTC
		or settings.webrtc_physics_fps <= 0.0
		or settings.webrtc_physics_fps
			== settings.target_network_fps
	):
		return
	var fps := settings.webrtc_physics_fps
	Engine.physics_ticks_per_second = int(fps)
	settings.target_network_fps = fps
	# Invalidate in-flight NTP pings (they carry
	# frame indices from the old tick rate).
	if frame_sync != null and is_client:
		frame_sync.invalidate_in_flight_pings()
	log.print(
		"Applied WebRTC physics FPS: %d"
		% int(fps),
		NetworkLogger.CATEGORY_CONNECTIONS,
	)


## Restore the default physics tick rate. Call
## when a match ends or returning to lobby.
func restore_default_physics_fps() -> void:
	var default_fps := 60.0
	if (
		Engine.physics_ticks_per_second
			!= int(default_fps)
	):
		Engine.physics_ticks_per_second = (
			int(default_fps))
		settings.target_network_fps = default_fps
		if frame_sync != null and is_client:
			frame_sync.invalidate_in_flight_pings()
		log.print(
			"Restored default physics FPS: %d"
			% int(default_fps),
			NetworkLogger.CATEGORY_CONNECTIONS,
		)


## Start server and begin listening for connections.
func server_start() -> void:
	log.print(
		"Starting server on port %d" % server_port,
		NetworkLogger.CATEGORY_CONNECTIONS
	)
	connector.server_enable_connections(server_port)


## Connect to server at specified address and port.
func client_connect(server_address: String, port: int) -> void:
	log.print(
		"Connecting to server at %s:%d" % [server_address, port],
		NetworkLogger.CATEGORY_CONNECTIONS
	)
	connector.client_connect_to_server(server_address, port)

# --- Include some convenient access to logging/error utilities ---------------

func print(
	message = "",
	category = &"Default", # NetworkLogger.CATEGORY_DEFAULT
) -> void:
	log.print(message, category)


func verbose(
	message = "",
	category = &"Default", # NetworkLogger.CATEGORY_DEFAULT
) -> void:
	log.print(message, category)


func warning(message = "", category = &"Default") -> void: # NetworkLogger.CATEGORY_DEFAULT
	log.warning(message, category)


func error(message = "", category = &"Default") -> void: # NetworkLogger.CATEGORY_DEFAULT
	log.error(message, category)


func fatal(message = "", category = &"Default") -> void: # NetworkLogger.CATEGORY_DEFAULT
	log.fatal(message, category)


func ensure(condition: bool, message = "") -> bool:
	return log.ensure(condition, message)


func ensure_valid(object, message = "") -> bool:
	return log.ensure(is_instance_valid(object), message)


func check(condition: bool, message = "") -> bool:
	return log.check(condition, message)


func check_valid(object, message = "") -> bool:
	return log.check(is_instance_valid(object), message)


## Check if current instance runs server logic
## (with error logging if not). Passes for
## dedicated servers and local mode.
func check_is_server() -> bool:
	if log == null:
		return runs_server_logic
	return log.check(
		runs_server_logic,
		"Expected server or local mode",
	)


## Check if current instance is client (with error logging if not).
func check_is_client() -> bool:
	if log == null:
		return is_client
	return log.check(
		is_client,
		"This logic assumes we should be a client, but we're a server"
	)


## Call a server-to-client RPC and, in local
## mode, also invoke it directly. Use for RPCs
## annotated with call_remote, which do not
## reach the local process. Bind arguments
## before passing:
##
##   Netcode.call_client_rpc_with_local_support(
##       _client_rpc_foo.bind(arg1, arg2))
func call_client_rpc_with_local_support(
	bound_method: Callable,
) -> void:
	bound_method.rpc()
	if is_local_mode:
		bound_method.call()

# -----------------------------------------------------------------------------
