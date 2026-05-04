class_name NetworkConnector
extends Node
## Manages ENet multiplayer peer connections between server and clients.
##
## NetworkConnector manages peer lifecycle (connection, disconnection) and
## provides connectivity status tracking. It is responsible for:
##
## - Creating and configuring server peers (server-side)
## - Creating and configuring client peers that connect to a server
##   (client-side)
## - Tracking connection status (is_connected_to_server)
## - Handling peer_connected and peer_disconnected signals
## - Managing graceful disconnection and session cleanup
##
## Usage:
## - Server: Call server_enable_connections(port) to start accepting client
##   connections
## - Client: Call client_connect_to_server(ip, port) to connect to a remote
##   server
## - Both: Listen to peer_connected/peer_disconnected signals for connection
##   events.

## Signal emitted when a peer declares their player count.
## assigned_ids is an Array[int] of the player IDs assigned by the server.
## player_attributes is an Array[Dictionary] of client-provided attributes.
signal peer_players_declared(
	peer_id: int,
	assigned_ids: Array[int],
	player_attributes: Array
)

## Emitted when client successfully connects to server.
signal connected(local_peer_id: int)

## Emitted when disconnection occurs (client or server).
signal disconnected(peer_id: int, reason: int)

## Emitted when client receives assigned player IDs from server.
signal player_ids_assigned(assigned_ids: Array[int])

## Tracks the reason for client disconnection.
enum DisconnectReason {
	UNKNOWN,
	CLIENT_INITIATED,
	SERVER_SHUTDOWN,
	CONNECTION_FAILED,
	CONNECTION_LOST,
	MATCH_FINISHED,
}

const SERVER_ID := 1

## RPC channel assignments. Each channel is an independent ENet ordering
## queue. Separating RPCs by purpose prevents head-of-line blocking
## between unrelated message types.
##
## Channel 0: Connection setup (safe default for new RPCs).
## Channel 1: Session control (pause, countdown, shutdown).
## Channel 2: Clock sync (latency-sensitive unreliable ping/pong).
## Channel 3: Game events (match lifecycle + entity events).
## Channel 4: Stats sync (periodic unreliable stat updates).
## Channel 5: Debug/dev (perf tracker, cheats).
const RPC_CHANNEL_DEFAULT := 0
const RPC_CHANNEL_SESSION_CONTROL := 1
const RPC_CHANNEL_CLOCK_SYNC := 2
const RPC_CHANNEL_GAME_EVENTS := 3
const RPC_CHANNEL_STATS := 4
const RPC_CHANNEL_DEBUG := 5


## ENet throttle tuning for faster unreliable
## packet ramp-up on new connections. ENet
## defaults start at ~31% send rate and ramp
## slowly (5s intervals, +2/32 per interval).
## These values reach full throughput within 1s.
const _ENET_THROTTLE_INTERVAL_MS := 1000
const _ENET_THROTTLE_ACCELERATION := 32
const _ENET_THROTTLE_DECELERATION := 2

## 75% of the 1MB outbound buffer size.
const _BUFFER_PRESSURE_THRESHOLD := 786432

## WebRTC signaling server (server-side only).
var _webrtc_signaling_server: WebRTCSignalingServer

## WebRTC signaling client (client-side only).
var _webrtc_signaling_client: WebRTCSignalingClient

## Custom WebRTC multiplayer peer using raw
## DataChannels (3 channels vs 8 SCTP streams).
var _webrtc_peer: WebRTCGamePeer

## Callable for validating player attributes (game-specific).
## Signature: func(attributes: Array, expected_count: int, peer_id: int) ->
## Array.
var player_attribute_validator: Callable

## Callable for getting local session data (session IDs, player count,
## attributes).
## Signature: func() -> Dictionary with keys: "session_ids", "player_count",
## "attributes".
var client_session_provider: Callable

## Optional session provider for backend validation (GameLift, etc.).
## Set this BEFORE server_enable_connections() or client_connect_to_server().
var session_provider: SessionProvider = null

var is_connected_to_server := false

## Last disconnect reason for displaying user-friendly messages.
var last_disconnect_reason := DisconnectReason.UNKNOWN

# Server-only: Counter for assigning sequential player IDs.
var _next_player_id: int = 1

# Dictionary<int, int>
var _player_id_to_peer_id := {}
# Dictionary<int, int>
var _player_id_to_local_player_index := {}

# Server-only: Stored peer declarations for replay
# after level reload. Maps peer_id to
# {assigned_ids: Array[int], attributes: Array}.
var _peer_declarations := {}


func _enter_tree() -> void:
	if Netcode.is_client:
		_client_update_is_connected_to_server()

	if not multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.connect(_on_peer_connected)
	if not multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	if not multiplayer.connection_failed.is_connected(
			_on_connection_failed):
		multiplayer.connection_failed.connect(
			_on_connection_failed)


func _ready() -> void:
	Netcode.log.print("NetworkConnector ready", NetworkLogger.CATEGORY_SYSTEM_INITIALIZATION)


func server_enable_connections(p_server_port: int) -> void:
	Netcode.check_is_server()

	var peer: MultiplayerPeer
	var result: Error
	var transport_name: String

	match Netcode.settings.transport_type:
		NetworkSettings.TransportType.WEBSOCKET:
			var ws := WebSocketMultiplayerPeer.new()
			# Larger buffers for 4-player state
			# replication. Default 64KB overflows
			# on web clients within seconds.
			ws.inbound_buffer_size = 1048576
			ws.outbound_buffer_size = 1048576
			ws.max_queued_packets = 16384
			# Godot listens on plain WebSocket
			# (no TLS) on the same port as ENet
			# (4433). nginx on port 4434 handles
			# TLS detection and routes both
			# ws:// (native) and wss:// (web)
			# traffic to this plain WS server.
			result = ws.create_server(
				p_server_port)
			peer = ws
			transport_name = "WebSocket"
		NetworkSettings.TransportType.WEBRTC:
			_server_start_webrtc(p_server_port)
			return
		_:
			var enet := ENetMultiplayerPeer.new()
			result = enet.create_server(
				p_server_port,
				Netcode.settings.max_client_count)
			peer = enet
			transport_name = "ENet"

	Netcode.log.check(
		result == Error.OK,
		"Failed to create %s server: error=%d"
		% [transport_name, result]
	)
	Netcode.log.check(
		peer.get_connection_status()
			!= MultiplayerPeer.CONNECTION_DISCONNECTED,
		"%s server peer is disconnected after creation"
		% transport_name
	)

	multiplayer.multiplayer_peer = peer

	Netcode.log.print(
		"Started %s multiplayer server: port=%d"
		% [transport_name, p_server_port],
		NetworkLogger.CATEGORY_CONNECTIONS
	)


func client_connect_to_server(
	p_server_ip_address: String,
	p_server_port: int
) -> void:
	Netcode.check_is_client()

	# Reset disconnect reason for new connection attempt.
	last_disconnect_reason = DisconnectReason.UNKNOWN

	var peer: MultiplayerPeer
	var result: Error
	var transport_name: String

	match Netcode.settings.transport_type:
		NetworkSettings.TransportType.WEBSOCKET:
			var ws := WebSocketMultiplayerPeer.new()
			# Larger buffers for 4-player state
			# replication. Default 64KB overflows
			# on web clients within seconds.
			ws.inbound_buffer_size = 1048576
			ws.outbound_buffer_size = 1048576
			ws.max_queued_packets = 16384
			# Web clients require wss:// (browser
			# mixed content policy). Native clients
			# use plain ws:// since the server runs
			# without TLS for native connections.
			# Local/preview always uses ws://.
			var is_local := (
				p_server_ip_address == "127.0.0.1"
				or p_server_ip_address == "localhost"
				or Netcode.is_preview)
			var use_tls := (
				not is_local
				and OS.has_feature("web"))
			var scheme := (
				"wss" if use_tls else "ws")
			result = ws.create_client(
				"%s://%s:%d"
				% [scheme,
					p_server_ip_address,
					p_server_port])
			peer = ws
			transport_name = "WebSocket"
		NetworkSettings.TransportType.WEBRTC:
			_client_start_webrtc(
				p_server_ip_address,
				p_server_port,
			)
			return
		_:
			var enet := ENetMultiplayerPeer.new()
			result = enet.create_client(
				p_server_ip_address, p_server_port)
			peer = enet
			transport_name = "ENet"

	Netcode.log.check(
		result == Error.OK,
		"Failed to start %s client: error=%d"
		% [transport_name, result],
	)
	if (peer.get_connection_status()
			== MultiplayerPeer
				.CONNECTION_DISCONNECTED):
		Netcode.log.error(
			"Failed to start %s client:"
			+ " status=DISCONNECTED"
			% transport_name,
			NetworkLogger.CATEGORY_CONNECTIONS,
		)
		# Emit signal so game can handle exit.
		disconnected.emit(
			-1, DisconnectReason.CONNECTION_FAILED)
		return

	multiplayer.multiplayer_peer = peer

	Netcode.log.print(
		"Started %s client: %s:%d"
		% [transport_name,
			p_server_ip_address,
			p_server_port],
		NetworkLogger.CATEGORY_CONNECTIONS,
	)


func _on_peer_connected(peer_id: int) -> void:
	if Netcode.is_server:
		Netcode.log.print(
			"Client connected: %d" % peer_id,
			NetworkLogger.CATEGORY_CONNECTIONS
		)
		_configure_enet_throttle(peer_id)
	else:
		# Clients only care about connecting to the server.
		if peer_id != SERVER_ID:
			return

		Netcode.log.print(
			"Connected to server: Local peer_id: %s" % multiplayer.get_unique_id(),
			NetworkLogger.CATEGORY_CONNECTIONS
		)
		_configure_enet_throttle(SERVER_ID)
		_client_update_is_connected_to_server()

		# Emit signal for game to handle (window title, etc.).
		connected.emit(multiplayer.get_unique_id())

		# Declare player count to server.
		_client_send_player_declaration()


func _on_peer_disconnected(peer_id: int) -> void:
	if Netcode.is_server:
		Netcode.log.print(
			"Client disconnected: %d" % peer_id,
			NetworkLogger.CATEGORY_CONNECTIONS
		)

		# Emit signal for game to handle (close server in preview mode, etc.).
		disconnected.emit(peer_id, DisconnectReason.UNKNOWN)

		# In preview mode, log when all clients have disconnected.
		# Game code handles shutdown via the disconnected signal.
		if Netcode.is_preview and multiplayer.get_peers().size() == 0:
			Netcode.log.print(
				"All clients disconnected in preview mode",
				NetworkLogger.CATEGORY_CONNECTIONS
			)
	else:
		# Clients only care about disconnecting from the server.
		if peer_id != SERVER_ID:
			return

		# Set reason if not already set by shutdown notification.
		if last_disconnect_reason == DisconnectReason.UNKNOWN:
			last_disconnect_reason = DisconnectReason.CONNECTION_LOST

		Netcode.log.print(
			"Disconnect from server",
			NetworkLogger.CATEGORY_CONNECTIONS
		)
		_client_update_is_connected_to_server()

		# Emit signal for game to handle (update window title, close app, etc.).
		disconnected.emit(peer_id, last_disconnect_reason)

		# In preview mode, log server disconnect.
		# Game code handles shutdown via the disconnected signal.
		if Netcode.is_preview:
			Netcode.log.print(
				"Server disconnected in preview mode",
				NetworkLogger.CATEGORY_CONNECTIONS
			)


func _on_connection_failed() -> void:
	Netcode.log.print(
		"Connection attempt failed",
		NetworkLogger.CATEGORY_CONNECTIONS,
	)
	last_disconnect_reason = DisconnectReason.CONNECTION_FAILED
	_client_update_is_connected_to_server()
	disconnected.emit(-1, DisconnectReason.CONNECTION_FAILED)


func _client_send_player_declaration() -> void:
	Netcode.log.check(client_session_provider.is_valid(),
		"client_session_provider not set, cannot declare players")

	# Get local session data from game.
	var session_data: Dictionary = client_session_provider.call()
	var session_ids: Array = session_data.get("session_ids", [])
	var player_count: int = session_data.get("player_count", 0)
	var player_attributes: Array = session_data.get("attributes", [])
	var backend_player_id: String = session_data.get(
		"backend_player_id", "")
	var profile_image_url: String = session_data.get(
		"profile_image_url", "")
	var auth_display_name: String = session_data.get(
		"display_name", "")

	Netcode.log.check(
		player_count == session_ids.size(),
		("Player count %d does not match "
		+ "session IDs size %d.")
		% [player_count, session_ids.size()],
	)

	Netcode.log.print(
		"Declaring %d player(s) to server" % player_count,
		NetworkLogger.CATEGORY_CONNECTIONS
	)

	var client_protocol_version: String = str(
		ProjectSettings.get_setting(
			"application/config/protocol_version",
			1,
		))

	# Call RPC to declare players.
	_server_rpc_declare_players.rpc_id(
		SERVER_ID,
		session_ids,
		player_attributes,
		client_protocol_version,
		backend_player_id,
		profile_image_url,
		auth_display_name,
	)


func _client_update_is_connected_to_server() -> void:
	if Netcode.is_server:
		is_connected_to_server = true
	else:
		is_connected_to_server = false
		for peer_id in multiplayer.get_peers():
			if peer_id == SERVER_ID:
				is_connected_to_server = true
				break


func server_close_multiplayer_session() -> void:
	Netcode.check_is_server()

	Netcode.log.print(
		"Ending network connections",
		NetworkLogger.CATEGORY_CONNECTIONS
	)

	multiplayer.multiplayer_peer.refuse_new_connections = true

	for peer_id in multiplayer.get_peers():
		if peer_id != SERVER_ID:
			multiplayer.multiplayer_peer.disconnect_peer(peer_id)


func server_disconnect_all_clients() -> void:
	Netcode.check_is_server()

	Netcode.log.print(
		"Disconnecting all clients (keeping session open)",
		NetworkLogger.CATEGORY_CONNECTIONS
	)

	# Disconnect all clients but keep session open for new connections.
	for peer_id in multiplayer.get_peers():
		if peer_id != SERVER_ID:
			multiplayer.multiplayer_peer.disconnect_peer(peer_id)


## Notify all clients that the server is shutting down.
## Sets their disconnect reason before the actual disconnect.
func server_notify_shutdown() -> void:
	Netcode.check_is_server()

	Netcode.log.print(
		"Notifying clients of server shutdown",
		NetworkLogger.CATEGORY_CONNECTIONS,
	)

	for peer_id in multiplayer.get_peers():
		if peer_id != SERVER_ID:
			_client_rpc_server_shutting_down.rpc_id(
				peer_id)


func client_disconnect() -> void:
	Netcode.check_is_client()

	# Mark as client-initiated disconnect.
	last_disconnect_reason = DisconnectReason.CLIENT_INITIATED

	Netcode.log.print(
		"Disconnecting from server", NetworkLogger.CATEGORY_CONNECTIONS
	)

	if not is_connected_to_server:
		return

	var peer := multiplayer.multiplayer_peer
	if (peer != null
			and peer.get_connection_status()
				!= MultiplayerPeer
					.CONNECTION_DISCONNECTED):
		peer.disconnect_peer(SERVER_ID)


## RPC called by client to declare how many players they have.
## This must be called before players are spawned on the server.
@rpc("any_peer", "call_remote", "reliable")
func _server_rpc_declare_players(
	session_ids: Array,
	player_attributes: Array,
	client_version: String,
	backend_player_id: String = "",
	profile_image_url: String = "",
	auth_display_name: String = "",
) -> void:
	Netcode.check_is_server()

	var peer_id := multiplayer.get_remote_sender_id()

	# Validate protocol version.
	var server_protocol_version: String = str(
		ProjectSettings.get_setting(
			"application/config/protocol_version",
			1,
		))

	if client_version != server_protocol_version:
		Netcode.log.warning(
			("Protocol mismatch from peer %d:"
			+ " client=%s, server=%s"
			+ " - disconnecting")
			% [
				peer_id,
				client_version,
				server_protocol_version,
			],
			NetworkLogger.CATEGORY_CONNECTIONS,
		)
		multiplayer.multiplayer_peer.disconnect_peer(
			peer_id)
		return

	Netcode.log.print(
		"Peer %d protocol validated: v%s"
		% [peer_id, client_version],
		NetworkLogger.CATEGORY_CONNECTIONS,
	)

	var player_count := session_ids.size()

	# Validate player count.
	if player_count < 1 or player_count > Netcode.settings.max_local_player_count:
		Netcode.log.warning(
			"Invalid player count from peer %d: %d (min=1, max=%d)" % [
				peer_id,
				player_count,
				Netcode.settings.max_local_player_count,
			],
			NetworkLogger.CATEGORY_CONNECTIONS
		)
		multiplayer.multiplayer_peer.disconnect_peer(peer_id)
		return

	Netcode.log.print(
		"Peer %d declared %d player(s)" % [peer_id, player_count],
		NetworkLogger.CATEGORY_CONNECTIONS
	)

	# Assign sequential player IDs.
	var assigned_ids: Array[int] = []
	for local_player_index in range(player_count):
		assigned_ids.append(_next_player_id)
		_player_id_to_peer_id[_next_player_id] = peer_id
		_player_id_to_local_player_index[_next_player_id] = local_player_index
		_next_player_id += 1

	# Validate session IDs if provider is set.
	if session_provider != null and session_provider.has_method(
		"server_validate_player_sessions"
	):
		session_provider.server_validate_player_sessions(
			peer_id,
			assigned_ids,
			session_ids,
			backend_player_id,
			profile_image_url,
			auth_display_name,
		)

	# Send assigned IDs back to client.
	_client_rpc_receive_player_ids.rpc_id(peer_id, assigned_ids)

	Netcode.log.print(
		"Assigned IDs %s to peer %d" % [assigned_ids, peer_id],
		NetworkLogger.CATEGORY_CONNECTIONS
	)

	# Validate and sanitize player attributes using callback.
	var validated_attributes: Array
	if player_attribute_validator.is_valid():
		validated_attributes = player_attribute_validator.call(
			player_attributes,
			player_count,
			peer_id
		)
	else:
		# No validator provided, use attributes as-is.
		validated_attributes = player_attributes

	# Store declaration for replay after level reload.
	_peer_declarations[peer_id] = {
		"assigned_ids": assigned_ids,
		"attributes": validated_attributes,
	}

	# Emit signal for Level and MatchStateSynchronizer to handle spawning.
	peer_players_declared.emit(peer_id, assigned_ids, validated_attributes)


## Returns stored peer declarations for replaying
## after a level reload. Each entry maps peer_id to
## {assigned_ids: Array[int], attributes: Array}.
func server_get_peer_declarations() -> Dictionary:
	return _peer_declarations


## Set up local mode player declarations without
## RPCs. Simulates the server-side player
## declaration flow for offline play.
func local_mode_setup(
	player_attributes: Array,
	session_ids: Array,
) -> void:
	is_connected_to_server = true

	var peer_id := SERVER_ID
	var player_count := session_ids.size()

	Netcode.log.print(
		"Local mode: Declaring %d player(s)"
		% player_count,
		NetworkLogger.CATEGORY_CONNECTIONS,
	)

	# Assign sequential player IDs.
	var assigned_ids: Array[int] = []
	for local_player_index in range(player_count):
		assigned_ids.append(_next_player_id)
		_player_id_to_peer_id[
			_next_player_id] = peer_id
		_player_id_to_local_player_index[
			_next_player_id] = local_player_index
		_next_player_id += 1

	# Validate attributes.
	var validated_attributes: Array
	if player_attribute_validator.is_valid():
		validated_attributes = (
			player_attribute_validator.call(
				player_attributes,
				player_count,
				peer_id,
			))
	else:
		validated_attributes = player_attributes

	# Store declaration for replay.
	_peer_declarations[peer_id] = {
		"assigned_ids": assigned_ids,
		"attributes": validated_attributes,
	}

	Netcode.log.print(
		"Local mode: Assigned IDs %s"
		% [assigned_ids],
		NetworkLogger.CATEGORY_CONNECTIONS,
	)

	# Emit signals for Level and
	# MatchStateSynchronizer.
	peer_players_declared.emit(
		peer_id,
		assigned_ids,
		validated_attributes,
	)
	player_ids_assigned.emit(assigned_ids)

	# Validate sessions through the provider
	# to trigger all_players_connected.
	if session_provider != null:
		(session_provider
			.server_validate_player_sessions(
				peer_id, assigned_ids,
				session_ids))


## Reset state set by local_mode_setup() so the
## connector is ready for a fresh session.
func reset_local_mode() -> void:
	is_connected_to_server = false
	last_disconnect_reason = (
		DisconnectReason.UNKNOWN)
	_next_player_id = 1
	_player_id_to_peer_id = {}
	_player_id_to_local_player_index = {}
	_peer_declarations = {}


## RPC called by server to send assigned player IDs to the client.
@rpc("authority", "call_remote", "reliable")
func _client_rpc_receive_player_ids(assigned_ids: Array[int]) -> void:
	Netcode.check_is_client()

	# Record local player IDs and indices.
	for local_player_index in range(assigned_ids.size()):
		var player_id := assigned_ids[local_player_index]
		_player_id_to_peer_id[player_id] = multiplayer.get_unique_id()
		_player_id_to_local_player_index[player_id] = local_player_index

	Netcode.log.print(
		"Received assigned player IDs: %s" % [assigned_ids],
		NetworkLogger.CATEGORY_CONNECTIONS
	)

	# Emit signal for game to handle (set local session, assign input devices).
	player_ids_assigned.emit(assigned_ids)


## RPC called by server to notify clients of imminent shutdown.
## Sets disconnect reason so clients display the correct message.
@rpc("authority", "call_remote", "reliable",
	RPC_CHANNEL_SESSION_CONTROL)
func _client_rpc_server_shutting_down() -> void:
	Netcode.check_is_client()
	last_disconnect_reason = (
		DisconnectReason.SERVER_SHUTDOWN)
	Netcode.log.print(
		"Server is shutting down",
		NetworkLogger.CATEGORY_CONNECTIONS,
	)
	# Close the connection on the next frame to
	# prevent buffer overflow from continued state
	# replication between the shutdown notification
	# and the actual server process exit.
	_client_close_connection.call_deferred()


## Close the client-side multiplayer peer. Called
## after receiving a server shutdown notification
## to stop receiving data immediately.
func _client_close_connection() -> void:
	var peer := multiplayer.multiplayer_peer
	if (peer != null
			and peer.get_connection_status()
				!= MultiplayerPeer
					.CONNECTION_DISCONNECTED):
		peer.close()


## Called by the server to register the player_id to peer_id mapping.
## Does NOT set local_player_index since the server doesn't have local players.
func server_register_player_id_to_peer_mapping(
		p_player_id: int,
		p_peer_id: int) -> void:
	_player_id_to_peer_id[p_player_id] = p_peer_id
	if Netcode.log.is_verbose:
		Netcode.log.verbose(
			"Registered player_id=%d -> peer_id=%d" % [
				p_player_id,
				p_peer_id
			],
			NetworkLogger.CATEGORY_CONNECTIONS
		)


func client_on_player_state_connected(
		p_player_id: int,
		p_peer_id: int,
		p_local_index: int) -> void:
	_player_id_to_peer_id[p_player_id] = p_peer_id
	_player_id_to_local_player_index[p_player_id] = p_local_index
	if Netcode.log.is_verbose:
		Netcode.log.verbose(
			"Client registered player state: player_id=%d, peer_id=%d, local_index=%d" % [
				p_player_id,
				p_peer_id,
				p_local_index
			],
			NetworkLogger.CATEGORY_CONNECTIONS
		)


## Gets the peer_id associated with a given player_id.
## Returns -1 if the player_id is not found (e.g., lobby player).
func get_peer_id_from_player_id(p_player_id: int) -> int:
	if _player_id_to_peer_id.has(p_player_id):
		return _player_id_to_peer_id[p_player_id]
	return 0


## Gets the local_player_index associated with a given player_id.
## Returns -1 if the player_id is not found (e.g., lobby player).
func get_local_player_index_from_player_id(p_player_id: int) -> int:
	if _player_id_to_local_player_index.has(p_player_id):
		return _player_id_to_local_player_index[p_player_id]
	return -1


## Returns true if the given WebSocket peer's
## outbound buffer exceeds the pressure threshold.
## Always returns false for ENet peers.
func is_peer_buffer_overloaded(
	peer_id: int,
) -> bool:
	var mp_peer := multiplayer.multiplayer_peer
	if not mp_peer is WebSocketMultiplayerPeer:
		return false
	var ws_peer := (
		mp_peer as WebSocketMultiplayerPeer
	)
	var ws_channel := ws_peer.get_peer(peer_id)
	if ws_channel == null:
		return false
	var buffered: int = (
		ws_channel
			.get_current_outbound_buffered_amount()
	)
	return buffered > _BUFFER_PRESSURE_THRESHOLD


## Configures ENet's unreliable packet throttle for
## faster ramp-up on new connections. By default,
## ENet starts at ~31% send rate for unreliable
## packets and increases slowly (every 5 seconds,
## +2/32). This causes state replication and NTP
## pings to be heavily throttled for tens of
## seconds on high-latency connections. This
## reconfigures the throttle to reach full
## throughput within ~1 second.
func _configure_enet_throttle(
	peer_id: int,
) -> void:
	var mp_peer := multiplayer.multiplayer_peer
	if not mp_peer is ENetMultiplayerPeer:
		return

	var enet_peer := (
		mp_peer as ENetMultiplayerPeer)
	var packet_peer := enet_peer.get_peer(
		peer_id)
	if packet_peer == null:
		return

	packet_peer.throttle_configure(
		_ENET_THROTTLE_INTERVAL_MS,
		_ENET_THROTTLE_ACCELERATION,
		_ENET_THROTTLE_DECELERATION,
	)

	Netcode.log.print(
		("Configured ENet throttle for"
		+ " peer %d: interval=%dms,"
		+ " accel=%d, decel=%d")
		% [
			peer_id,
			_ENET_THROTTLE_INTERVAL_MS,
			_ENET_THROTTLE_ACCELERATION,
			_ENET_THROTTLE_DECELERATION,
		],
		NetworkLogger.CATEGORY_CONNECTIONS,
	)


# =============================================================
# WebRTC transport
# =============================================================


## Start the WebRTC signaling server and create
## the WebRTCGamePeer in server mode.
func _server_start_webrtc(
	p_server_port: int,
) -> void:
	# Close the existing multiplayer peer (ENet)
	# to release the UDP socket on p_server_port.
	# The WebRTC ICE agent needs to bind to this
	# port so its candidates use a port that
	# GameLift forwards. Without this, the ENet
	# socket holds the port and the ICE agent
	# picks an ephemeral port that is unreachable
	# through GameLift's container port mapping.
	var old_peer := multiplayer.multiplayer_peer
	if (old_peer != null
			and old_peer.get_connection_status()
				!= MultiplayerPeer
					.CONNECTION_DISCONNECTED):
		old_peer.close()
	multiplayer.multiplayer_peer = null

	# Start signaling WebSocket server on the same
	# port (TCP). WebRTC data flows over UDP, so
	# there is no port conflict.
	if _webrtc_signaling_server != null:
		_webrtc_signaling_server.stop()
		_webrtc_signaling_server.queue_free()

	_webrtc_signaling_server = (
		WebRTCSignalingServer.new())
	_webrtc_signaling_server.name = (
		"WebRTCSignalingServer")
	add_child(_webrtc_signaling_server)
	# Signaling listens on its own port when settings.signaling_port
	# is non-zero (Edgegap: 4434/TCP). Otherwise fall back to the
	# game-data port for the legacy GameLift-era single-port setup.
	var signaling_port: int = (
		Netcode.settings.signaling_port
		if Netcode.settings.signaling_port > 0
		else p_server_port)
	_webrtc_signaling_server.start(signaling_port)

	# Create custom WebRTC peer in server mode.
	# Uses 3 negotiated DataChannels (reliable,
	# unreliable ordered, unreliable) instead of
	# WebRTCMultiplayerPeer's 6-8 SCTP streams.
	_webrtc_peer = WebRTCGamePeer.new()
	_webrtc_peer.create_server()
	multiplayer.multiplayer_peer = _webrtc_peer

	# Connect signaling signals.
	_webrtc_signaling_server.peer_signaled.connect(
		_on_webrtc_peer_signaled)

	Netcode.log.print(
		(
			"Started WebRTC server: data_port=%d"
			+ " signaling_port=%d"
		) % [p_server_port, signaling_port],
		NetworkLogger.CATEGORY_CONNECTIONS,
	)


## Called when a client completes signaling. Adds
## the client's WebRTCPeerConnection to the custom
## peer, which creates 3 negotiated DataChannels.
func _on_webrtc_peer_signaled(
	peer_connection: WebRTCPeerConnection,
	peer_id: int,
) -> void:
	if _webrtc_peer == null:
		return
	_webrtc_peer.add_peer(
		peer_connection, peer_id)
	Netcode.log.print(
		"WebRTC: added peer %d" % peer_id,
		NetworkLogger.CATEGORY_CONNECTIONS,
	)


## Start WebRTC signaling as a client. Connects to
## the server's signaling WebSocket, performs SDP/ICE
## exchange, then creates the multiplayer peer.
func _client_start_webrtc(
	p_server_ip_address: String,
	p_server_port: int,
) -> void:
	# Reset disconnect reason for new connection.
	last_disconnect_reason = (
		DisconnectReason.UNKNOWN)

	# Determine signaling WebSocket URL. Web clients
	# use wss:// through nginx, native clients use
	# ws:// for local/preview.
	var is_local := (
		p_server_ip_address == "127.0.0.1"
		or p_server_ip_address == "localhost"
		or Netcode.is_preview)
	var use_tls := (
		not is_local and OS.has_feature("web"))
	var scheme := "wss" if use_tls else "ws"
	var ws_url := "%s://%s:%d" % [
		scheme,
		p_server_ip_address,
		p_server_port,
	]

	if _webrtc_signaling_client != null:
		_webrtc_signaling_client.stop()
		_webrtc_signaling_client.queue_free()

	_webrtc_signaling_client = (
		WebRTCSignalingClient.new())
	_webrtc_signaling_client.name = (
		"WebRTCSignalingClient")
	add_child(_webrtc_signaling_client)

	# Use a temporary peer ID based on hash. The
	# server assigns the real ID during the
	# multiplayer handshake.
	var temp_peer_id := (
		(Time.get_ticks_msec() % 2147483646) + 2)

	_webrtc_signaling_client.peer_created.connect(
		_on_webrtc_client_peer_created.bind(
			temp_peer_id))
	_webrtc_signaling_client.completed.connect(
		_on_webrtc_signaling_completed)
	_webrtc_signaling_client.failed.connect(
		_on_webrtc_signaling_failed)

	_webrtc_signaling_client.start(
		ws_url, temp_peer_id, p_server_port)

	Netcode.log.print(
		"Started WebRTC client signaling: %s"
		% ws_url,
		NetworkLogger.CATEGORY_CONNECTIONS,
	)


## Called when the client's WebRTCPeerConnection is
## created. Sets up the custom WebRTC peer with 3
## negotiated DataChannels and adds the server
## connection.
func _on_webrtc_client_peer_created(
	peer_connection: WebRTCPeerConnection,
	client_id: int,
) -> void:
	_webrtc_peer = WebRTCGamePeer.new()
	_webrtc_peer.create_client(client_id)
	# Add server peer. Creates 3 negotiated
	# DataChannels (reliable, unreliable ordered,
	# unreliable).
	_webrtc_peer.add_peer(
		peer_connection, SERVER_ID)
	multiplayer.multiplayer_peer = _webrtc_peer

	Netcode.log.print(
		("WebRTC: custom peer created"
		+ " (client_id=%d)") % client_id,
		NetworkLogger.CATEGORY_CONNECTIONS,
	)


## Called when signaling completes and the
## DataChannel is open.
func _on_webrtc_signaling_completed(
	_peer_connection: WebRTCPeerConnection,
) -> void:
	Netcode.log.print(
		"WebRTC: signaling complete, connected",
		NetworkLogger.CATEGORY_CONNECTIONS,
	)


## Called when client signaling fails after all
## retries.
func _on_webrtc_signaling_failed(
	error: String,
) -> void:
	Netcode.log.error(
		"WebRTC signaling failed: %s" % error,
		NetworkLogger.CATEGORY_CONNECTIONS,
	)
	disconnected.emit(
		-1, DisconnectReason.CONNECTION_FAILED)
