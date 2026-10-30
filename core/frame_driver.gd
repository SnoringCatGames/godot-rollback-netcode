class_name FrameDriver
extends Node
## Core frame-synchronous simulation engine for client-prediction rollback
## networking.
##
## FrameDriver is the heart of the networking system, managing deterministic
## frame-based simulation at a fixed FPS (independent of render framerate). It
## coordinates all networked entities through a three-phase processing cycle:
##
## 1. **_pre_network_process**: Restore state from rollback buffer for current
##    frame
## 2. **_network_process**: Execute game logic (movement, physics, input
##    handling)
## 3. **_post_network_process**: Pack and record new state to rollback buffer
##
## Key responsibilities:
## - Maintains server_frame_index as the primary synchronization primitive
## - Manages the rollback buffer
## - Detects state mismatches and triggers rollback reconciliation
## - Coordinates re-simulation of frames during rollback
## - Handles fast-forwarding when client falls behind server
## - Registers and manages all ReconcilableState and FrameProcessor nodes
##
## Networked entities must extend either ReconcilableState or FrameProcessor to
## participate in this frame-synchronous cycle.
## - ReconcilableState nodes support server-mismatch detection and rollback
## - FrameProcessor nodes simply process each frame without rollback support
##
## Frame timing:
## - Target: 60 FPS (TARGET_NETWORK_TIME_STEP_SEC = 1/60 ≈ 0.01666 seconds)
## - Frames are identified by server_frame_index, which increments directly on
##   each physics tick for perfect synchronization with Godot's physics loop
## - Timestamps are calculated from frame indices, with periodic wall-clock
##   re-sync every 30 seconds to maintain accurate logging timestamps
## - Times are stored in microseconds for precision
##
## Rollback mechanism:
## - queue_rollback() schedules rollback to a specific frame (conflict
##   detection).
## - _rollback_and_reprocess() restores state and re-simulates up to current
##   frame.
## - Only one rollback occurs per _network_process, earliest frame takes
##   priority.


## Emitted when pause state changes (for UI updates).
signal pause_state_changed(is_paused: bool, initiator_peer_id: int)

## Emitted when a pause is requested (for validation/accounting).
signal pause_requested(peer_id: int)

## Emitted when an unpause is requested.
signal unpause_requested(peer_id: int)

## Emitted when match start countdown begins (for game-specific UI).
## countdown_end_frame is the frame index when countdown ends.
signal match_start_countdown_started(countdown_end_frame: int)

## Emitted when match start countdown ends and gameplay begins.
signal match_start_countdown_ended

## This determines the period we use between frames that we record in rollback
## buffers.
##
## Network state will presumably be slower than this in practice. When that
## occurs, we fill-in empty frames by extrapolating from the most-recent filled
## frame.

# Network tick rate properties derived from Netcode.settings.
var target_network_fps: float:
	get:
		return Netcode.settings.target_network_fps if Netcode.settings else 60.0

var target_network_time_step_sec: float:
	get:
		return 1.0 / target_network_fps

var target_network_time_step_usec: int:
	get:
		return floori(1_000_000 / target_network_fps)

## Number of simulation frames between state sends.
## 1 = send every frame (default when
## target_state_send_fps is 0 or >= sim rate).
var state_send_interval: int:
	get:
		if not Netcode.settings:
			return 1
		var send_fps := _resolve_state_send_fps()
		if send_fps <= 0.0 or send_fps >= target_network_fps:
			return 1
		return maxi(1, roundi(
			target_network_fps / send_fps
		))


## Returns true if the current frame should send
## replicated state over the network.
func is_state_send_frame() -> bool:
	return (server_frame_index % state_send_interval) == 0


func _resolve_state_send_fps() -> float:
	var settings := Netcode.settings
	if settings == null:
		return 0.0
	# Check per-transport override first.
	match settings.transport_type:
		NetworkSettings.TransportType.ENET:
			if settings.enet_state_send_fps > 0.0:
				return settings.enet_state_send_fps
		NetworkSettings.TransportType.WEBSOCKET:
			if settings.websocket_state_send_fps > 0.0:
				return settings.websocket_state_send_fps
		NetworkSettings.TransportType.WEBRTC:
			if settings.webrtc_state_send_fps > 0.0:
				return settings.webrtc_state_send_fps
	# Fall back to global setting.
	return settings.target_state_send_fps

## Current frame index. Incremented directly on each physics tick in
## _pre_physics_process(). Drives all frame-synchronous simulation and rollback.
## This is the single source of truth for frame progression and network
## synchronization.
var server_frame_index := 0

## Tracks whether frame tracking has been initialized. Initialization is
## deferred until the first physics tick, preventing fast-forward at startup.
var _is_frame_tracking_initialized := false

## Timestamp when server_frame_index was last manually reset (for new matches).
## Used to suppress frame sync warnings during the expected synchronization period.
var _frame_reset_time_usec := 0

## Grace period in seconds after frame reset to suppress sync warnings.
const FRAME_SYNC_GRACE_PERIOD_SEC := 3.0

## Returns true if we're within the grace period after a frame reset.
## During this time, frame sync warnings are suppressed as they're expected.
var is_in_sync_grace_period: bool:
	get:
		if _frame_reset_time_usec == 0:
			return false
		var elapsed_usec := Time.get_ticks_usec() - _frame_reset_time_usec
		return elapsed_usec < (FRAME_SYNC_GRACE_PERIOD_SEC * 1_000_000)

## Timestamp of the last backward hard reset (client was ahead of server).
## Used to suppress fast-forwards from stale buffered state packets.
var _hard_reset_backward_time_usec := 0

## Returns true if fast-forwards should be suppressed after a backward
## hard reset. Stale state packets buffered before the reset would
## otherwise race the frame counter back up.
var is_suppressing_fast_forward: bool:
	get:
		if _hard_reset_backward_time_usec == 0:
			return false
		var elapsed_usec := (
			Time.get_ticks_usec()
			- _hard_reset_backward_time_usec)
		return elapsed_usec < (
			FRAME_SYNC_GRACE_PERIOD_SEC
			* 1_000_000)

## Pauses frame simulation. Starts paused by default - server unpauses when
## ready (e.g., after all players connect in GameLift). When paused,
## _pre_physics_process returns early without incrementing server_frame_index
## or running network processing.
var _is_paused := true

## Frame index when pause started. Used to calculate cumulative pause duration,
## filter incoming states during pause, and revert frame tracking after pause.
var _pause_start_frame_index := 0

## Wall-clock time when the pause started. A pause stops physics
## ticks, so server_frame_index does not advance while paused and
## a frame-index difference always reads 0 (RN8); the real pause
## length comes from this timestamp.
var _pause_start_time_usec := 0

## Total frames paused across all pause periods. This is subtracted from
## time-based frame calculations to maintain continuous frame progression
## without gaps.
var _cumulative_paused_frames := 0

## History of pause periods for debugging/logging.
## Array of { start_frame: int, end_frame: int, duration_frames: int }
var _pause_history: Array[Dictionary] = []

## Optional validator for pause requests (server-only). When set, called
## with (peer_id: int) before executing a client-initiated pause. Must
## return Dictionary with:
## - "allowed": bool (false to reject the pause request)
## - "pauses_used": int (cumulative pause count for the initiator)
var server_pause_validator: Callable = Callable()

## Tracks last pause request time for rate limiting (microseconds).
var _last_pause_request_time_usec := 0

## Peer ID of the client that initiated the current pause.
var _pause_initiator_peer_id: int = 0

## Number of pauses used by the initiator at the time of pause.
var _pause_initiator_pauses_used: int = 0

## Time when the current pause will automatically unpause (microseconds).
## This is replicated to clients for countdown display.
var _pause_auto_unpause_time_usec: int = 0

## SceneTreeTimer for auto-unpause (server-only).
var _pause_auto_unpause_timer: SceneTreeTimer = null

## Frame index when match start countdown ends. States before this frame are
## discarded. Set automatically when match starts.
var match_start_countdown_end_frame_index := -1

## Tracks if the initial match start countdown has been triggered.
## Used to distinguish first unpause (match start) from subsequent unpauses.
var _has_match_start_countdown_started := false

## Tracks if the initial match start countdown has completed.
var _has_match_start_countdown_ended := false

## Returns true if match start countdown is currently active.
var is_match_start_countdown_active: bool:
	get:
		return (
			match_start_countdown_end_frame_index >= 0
			and server_frame_index
				< match_start_countdown_end_frame_index
		)

## Interval for periodic wall-clock re-sync to maintain accurate timestamps for
## logging. Re-sync is handled automatically via SceneTree timers.
const WALL_CLOCK_RESYNC_INTERVAL_SEC := 30.0

var _networked_state_nodes: Array[ReconcilableState] = []

var _frame_processor_nodes: Array[FrameProcessor] = []

var _queued_rollback_frame_index := 0
var _queued_rollback_cause: String = ""

## True during rollback re-simulation. Used to suppress re-sending
## of client input that was already transmitted during forward sim.
var is_resimulating := false

## Rollback tracking metrics (for performance monitoring).
var last_rollback_frame_count := 0
var last_rollback_duration_usec := 0
var total_rollbacks := 0

## Fast-forward tracking metrics (for performance monitoring).
var last_fastforward_frame_count := 0
var last_fastforward_duration_usec := 0
var total_fastforwards := 0

## Number of extra frames to process (one per physics
## tick) for gradual clock catch-up. Set by
## FrameSynchronizer when the client drifts slightly
## behind the server. Smooths correction over multiple
## ticks instead of processing many frames at once.
var _catchup_frames_remaining := 0

## Number of physics ticks to skip (one per tick) for
## gradual clock slow-down. Set by FrameSynchronizer
## when the client drifts slightly ahead of the server.
## Mirrors _catchup_frames_remaining for the opposite
## direction.
var _slowdown_frames_remaining := 0

## Returns true when the frame driver is gradually
## catching up to the server frame. Used to suppress
## redundant state-triggered fast-forwards.
var is_catching_up: bool:
	get:
		return _catchup_frames_remaining > 0

## Returns true when the frame driver is gradually
## slowing down to let the server catch up. Used to
## suppress redundant corrections during slow-down.
var is_slowing_down: bool:
	get:
		return _slowdown_frames_remaining > 0

var rollback_buffer_size: int:
	get:
		return ceili(
			Netcode.settings.rollback_buffer_duration_sec
			* target_network_fps
		)

var oldest_rollbackable_frame_index: int:
	get:
		# - When processing a frame, we must be able to consider both the target
		#   frame as well as the previous frame, so we can't rollback to the
		#   oldest recorded frame.
		# - Also, some buffers could already contain networked state for the
		#   next frame, so those buffers have one fewer past frames.
		return max(server_frame_index - rollback_buffer_size + 3, 1)

## Whether frame simulation is currently paused.
var is_paused: bool:
	get:
		return _is_paused

## Frame index when pause started. Returns 0 if not currently paused.
var pause_start_frame: int:
	get:
		return _pause_start_frame_index if _is_paused else 0


func _ready() -> void:
	Netcode.log.print("FrameDriver ready", NetworkLogger.CATEGORY_SYSTEM_INITIALIZATION)

	if not Engine.is_editor_hint():
		# Connect to ProcessSentinel for deterministic frame ordering.
		# ProcessSentinel places helper nodes at scene tree root with extreme
		# priority values to ensure this runs before all other physics processing.
		Netcode.process_sentinel.pre_physics_process.connect(_pre_physics_process)

		# Start paused - server will unpause when ready (e.g., after all players
		# connect).
		if is_inside_tree():
			get_tree().paused = true

		# In preview mode (local multi-instance testing), track client
		# connections and unpause when all expected clients have connected.
		if Netcode.is_preview and Netcode.is_server:
			multiplayer.peer_connected.connect(_on_preview_peer_connected)
			# Check if clients are already connected.
			_check_preview_clients_connected()


func client_reset() -> void:
	# Reset frame index for new match to sync
	# with server's reset.
	server_frame_index = 0
	# Prevent frame index from incrementing
	# during loading/matchmaking. Frame tracking
	# re-initializes when the connection starts.
	_is_frame_tracking_initialized = false
	# Start grace period to suppress expected
	# frame sync warnings.
	_frame_reset_time_usec = Time.get_ticks_usec()
	# Reset backward hard reset suppression.
	_hard_reset_backward_time_usec = 0
	# Cancel any in-progress gradual catch-up or
	# slow-down.
	_catchup_frames_remaining = 0
	_slowdown_frames_remaining = 0
	# Start paused so client waits for server's
	# unpause signal before transitioning from
	# LOADING to GAME screen.
	_is_paused = true
	# Reset match start countdown state from
	# previous match.
	match_start_countdown_end_frame_index = -1
	_has_match_start_countdown_started = false
	_has_match_start_countdown_ended = false
	# Reset NTP sync so first ping fires
	# immediately on new connection.
	if Netcode.frame_sync != null:
		Netcode.frame_sync.client_reset()


## Handles peer connections in preview mode to auto-unpause when ready.
func _on_preview_peer_connected(_peer_id: int) -> void:
	_check_preview_clients_connected()


## Checks if all expected clients are connected in preview mode.
func _check_preview_clients_connected() -> void:
	if not Netcode.is_preview or not Netcode.is_server:
		return

	var connected_count := multiplayer.get_peers().size()

	Netcode.log.print(
		"Preview mode: %d/%d clients connected" % [
			connected_count,
			Netcode.settings.preview_client_count,
		],
		NetworkLogger.CATEGORY_NETWORK_SYNC
	)

	if connected_count >= Netcode.settings.preview_client_count:
		Netcode.log.print(
			"All expected clients connected; Unpausing game",
			NetworkLogger.CATEGORY_NETWORK_SYNC
		)
		# Disconnect signal to avoid re-checking.
		if multiplayer.peer_connected.is_connected(_on_preview_peer_connected):
			multiplayer.peer_connected.disconnect(_on_preview_peer_connected)
		server_set_is_paused(false)


## Re-enable preview mode auto-unpause for a new match.
##
## Call this when starting a new match in preview mode to reconnect the
## peer_connected signal and re-enable auto-unpause logic.
func server_reset_preview_mode_unpause() -> void:
	if not Netcode.is_preview or not Netcode.is_server:
		return

	Netcode.log.print(
		"Resetting preview mode auto-unpause for new match",
		NetworkLogger.CATEGORY_NETWORK_SYNC
	)

	# Reconnect the signal if not already connected.
	if not multiplayer.peer_connected.is_connected(_on_preview_peer_connected):
		multiplayer.peer_connected.connect(_on_preview_peer_connected)

	# Check if clients are already connected.
	_check_preview_clients_connected()


## Pause or unpause frame simulation.
##
## When paused, frame processing stops completely - server_frame_index does not
## increment and no network processing occurs. This is used by GameLift to wait
## for all players to connect before starting the game.
##
## @param paused: true to pause, false to unpause.
func server_set_is_paused(paused: bool) -> void:
	if paused:
		_server_execute_pause()
	else:
		_server_execute_unpause()


func client_request_toggle_pause() -> void:
	if is_paused:
		client_request_unpause()
	else:
		client_request_pause()


## Request pause from client. Only works if Netcode.settings.is_server_pause_enabled.
func client_request_pause() -> void:
	Netcode.check_is_client()
	_server_rpc_client_request_pause.rpc_id(NetworkConnector.SERVER_ID)


## Request unpause from client. Only works if Netcode.settings.is_server_pause_enabled.
func client_request_unpause() -> void:
	Netcode.check_is_client()
	_server_rpc_request_unpause.rpc_id(NetworkConnector.SERVER_ID)

## Client requests server to pause.


@rpc("any_peer", "call_remote", "reliable", NetworkConnector.RPC_CHANNEL_SESSION_CONTROL)
func _server_rpc_client_request_pause() -> void:
	Netcode.check_is_server()

	var peer_id := multiplayer.get_remote_sender_id()

	if not Netcode.settings.is_server_pause_enabled:
		Netcode.log.print(
			"Client %d requested pause, but server pause is disabled" % peer_id,
						NetworkLogger.CATEGORY_NETWORK_SYNC
		)
		return

	# Block pause requests during match start countdown.
	if is_match_start_countdown_active:
		Netcode.log.print(
			"Client %d requested pause during match start countdown - rejected" % peer_id,
			NetworkLogger.CATEGORY_NETWORK_SYNC
		)
		return

	# Rate limit pause requests.
	var current_time := Time.get_ticks_usec()
	var cooldown_usec := int(Netcode.settings.pause_request_cooldown_sec * 1_000_000)
	if current_time - _last_pause_request_time_usec < cooldown_usec:
		return

	# Validate with game-level logic (pause limits, match state, etc.).
	var pauses_used := 0
	if server_pause_validator.is_valid():
		var result: Dictionary = server_pause_validator.call(peer_id)
		if not result.get("allowed", true):
			Netcode.log.print(
				("Client %d pause rejected by "
				+"game validator")
				% peer_id,
				NetworkLogger.CATEGORY_NETWORK_SYNC
			)
			return
		pauses_used = result.get("pauses_used", 0)

	pause_requested.emit(peer_id)

	_last_pause_request_time_usec = current_time
	_server_execute_pause(peer_id, pauses_used)


## Client requests server to unpause.
@rpc("any_peer", "call_remote", "reliable", NetworkConnector.RPC_CHANNEL_SESSION_CONTROL)
func _server_rpc_request_unpause() -> void:
	Netcode.check_is_server()

	var peer_id := multiplayer.get_remote_sender_id()

	if not Netcode.settings.is_server_pause_enabled:
		Netcode.log.print(
			"Client %d requested unpause, but server pause is disabled" % peer_id,
			NetworkLogger.CATEGORY_NETWORK_SYNC
		)
		return

	# Check if requesting peer is the pause initiator.
	if peer_id != _pause_initiator_peer_id:
		Netcode.log.print(
			"Client %d requested unpause, but only initiator (peer %d) can unpause" % [
				peer_id,
				_pause_initiator_peer_id,
			],
			NetworkLogger.CATEGORY_NETWORK_SYNC
		)
		return

	# Rate limit pause requests.
	var current_time := Time.get_ticks_usec()
	var cooldown_usec := int(Netcode.settings.pause_request_cooldown_sec * 1_000_000)
	if current_time - _last_pause_request_time_usec < cooldown_usec:
		return

	_last_pause_request_time_usec = current_time

	# Emit signal for game to handle.
	unpause_requested.emit(peer_id)

	_server_execute_unpause()

## Server notifies all clients of pause.


@rpc("authority", "call_remote", "reliable", NetworkConnector.RPC_CHANNEL_SESSION_CONTROL)
func _client_rpc_notify_pause(
	server_pause_frame: int,
	pause_initiator_peer_id: int,
	pause_initiator_pauses_used: int,
) -> void:
	Netcode.check_is_client()

	_client_execute_pause_at_server_frame(
		server_pause_frame,
		pause_initiator_peer_id,
		pause_initiator_pauses_used,
	)

## Server notifies all clients of unpause.


@rpc("authority", "call_remote", "reliable", NetworkConnector.RPC_CHANNEL_SESSION_CONTROL)
func _client_rpc_notify_unpause(
		server_unpause_frame: int,
		server_cumulative_paused_frames: int,
) -> void:
	Netcode.check_is_client()

	_client_execute_unpause_at_server_frame(
		server_unpause_frame,
		server_cumulative_paused_frames,
	)


## Server notifies clients to start match start countdown.
## Clients pause locally and unpause when countdown ends.
## server_current_frame lets the client sync its frame
## counter immediately, eliminating the initial frame drift
## that would otherwise persist until the next NTP ping.
## Default of -1 provides backward compatibility with
## servers that send the old 1-parameter version.
@rpc("authority", "call_remote", "reliable", NetworkConnector.RPC_CHANNEL_SESSION_CONTROL)
func _client_rpc_start_match_start_countdown(
	countdown_end_frame: int,
	server_current_frame: int = -1,
) -> void:
	Netcode.check_is_client()

	# Sync frame counter to the server's frame
	# if provided. This eliminates the drift
	# caused by the RPC transmission delay.
	var previous_frame := server_frame_index
	if server_current_frame >= 0:
		server_frame_index = server_current_frame
		_is_frame_tracking_initialized = true
		# Invalidate in-flight NTP pings so stale
		# burst pongs don't override this sync.
		if Netcode.frame_sync != null:
			(Netcode.frame_sync
				.invalidate_in_flight_pings())

	match_start_countdown_end_frame_index = (
		countdown_end_frame)
	_has_match_start_countdown_started = true
	_is_paused = false

	Netcode.log.print(
		("Starting match start countdown"
		+" (%d frames), synced frame %d->%d")
		% [
			countdown_end_frame,
			previous_frame,
			server_frame_index,
		],
		NetworkLogger.CATEGORY_GAME_STATE,
	)

	# Emit pause_state_changed to trigger screen
	# transition (LOADING -> GAME). This must
	# happen before pausing tree so UI transitions
	# work.
	pause_state_changed.emit(false, 0)

	# Pause client tree during match start
	# countdown (characters won't move). Will be
	# unpaused when countdown ends in
	# _pre_physics_process.
	if is_inside_tree():
		get_tree().paused = true

	# Emit signal for game-specific UI (e.g.,
	# show match start countdown display).
	match_start_countdown_started.emit(
		countdown_end_frame)


## Server notifies all clients of impending graceful shutdown.
## Called before disconnecting clients during Spot instance termination.
@rpc("authority", "call_remote", "reliable", NetworkConnector.RPC_CHANNEL_SESSION_CONTROL)
func _client_rpc_notify_shutdown(shutdown_message: String) -> void:
	Netcode.check_is_client()

	Netcode.log.print(
		"Server shutdown notification: %s" % shutdown_message,
		NetworkLogger.CATEGORY_CONNECTIONS
	)

	# Store reason in connector for disconnect handling.
	Netcode.connector.last_disconnect_reason = NetworkConnector.DisconnectReason.SERVER_SHUTDOWN


## Internal method to execute pause on server or client.
##
## @param initiator_peer_id: Peer ID that initiated the pause (0 for system pause).
## @param pauses_used: Number of pauses used by initiator after this pause.
func _server_execute_pause(
	initiator_peer_id: int = 0,
	pauses_used: int = 0
) -> void:
	if _is_paused:
		return

	_is_paused = true
	_pause_start_frame_index = server_frame_index
	_pause_start_time_usec = Time.get_ticks_usec()
	_pause_initiator_peer_id = initiator_peer_id
	_pause_initiator_pauses_used = pauses_used

	# Calculate auto-unpause time for replication to clients
	# (for countdown).
	_pause_auto_unpause_time_usec = (
		Time.get_ticks_usec()
		+ int(
			Netcode.settings.max_pause_duration_sec
			* 1_000_000
		)
	)

	# Schedule auto-unpause using timer system.
	if Netcode.runs_server_logic:
		_pause_auto_unpause_timer = get_tree().create_timer(Netcode.settings.max_pause_duration_sec)
		_pause_auto_unpause_timer.timeout.connect(func():
			Netcode.log.print("Auto-unpausing after timeout", NetworkLogger.CATEGORY_NETWORK_SYNC)
			_server_execute_unpause()
		)

	# Clean up buffer frames after pause started.
	_cleanup_buffer_after_pause()

	# Clear queued rollback - it's based on invalid post-pause state.
	_queued_rollback_frame_index = 0
	_queued_rollback_cause = ""

	# Notify clients (if server and in tree for RPC).
	if Netcode.runs_server_logic and is_inside_tree():
		Netcode.call_client_rpc_with_local_support(
			_client_rpc_notify_pause.bind(
				server_frame_index,
				_pause_initiator_peer_id,
				_pause_initiator_pauses_used,
			))

	# Pause Godot scene tree.
	if is_inside_tree():
		get_tree().paused = true

	# Emit signal for UI updates.
	pause_state_changed.emit(true, initiator_peer_id)

	Netcode.log.print(
		"Server paused at frame %d by peer %d" % [server_frame_index, initiator_peer_id],
		NetworkLogger.CATEGORY_NETWORK_SYNC
	)


## Frames the recorded pause start represents at the
## target rate, as of now_usec; 0 with no start recorded.
func _paused_wall_frames(now_usec: int) -> int:
	if _pause_start_time_usec <= 0:
		return 0
	return int(
		(now_usec - _pause_start_time_usec)
		* target_network_fps / 1_000_000.0)


## Internal method to execute unpause on server or client.
func _server_execute_unpause() -> void:
	if not _is_paused:
		return

	# Frame indices freeze while paused, so measure the pause
	# on the wall clock (RN8); keep the frame difference when
	# it is larger (drivers whose frames advance while paused).
	var pause_duration_frames := (
		server_frame_index - _pause_start_frame_index)
	if _pause_start_time_usec > 0:
		var wall_frames := _paused_wall_frames(
			Time.get_ticks_usec())
		pause_duration_frames = maxi(
			pause_duration_frames, wall_frames)

		_pause_start_time_usec = 0
	_cumulative_paused_frames += pause_duration_frames

	# Record pause history.
	_pause_history.append(
		{
			"start_frame": _pause_start_frame_index,
			"end_frame": server_frame_index,
			"duration_frames": pause_duration_frames,
		},
	)

	_is_paused = false

	# Unpause the scene tree (paused in _ready).
	if is_inside_tree():
		get_tree().paused = false

	# Cancel auto-unpause timeout (server-only).
	# SceneTreeTimer cannot be canceled once started, so we just clear the
	# reference.
	if Netcode.runs_server_logic and _pause_auto_unpause_timer != null:
		_pause_auto_unpause_timer = null

	# Reset pause state variables.
	_pause_initiator_peer_id = 0
	_pause_initiator_pauses_used = 0
	_pause_auto_unpause_time_usec = 0

	# Check if this is the initial match start and countdown is enabled.
	var is_starting_match_start_countdown := (
		Netcode.runs_server_logic
		and not _has_match_start_countdown_started
		and Netcode.settings.match_start_countdown_sec > 0
	)

	if is_starting_match_start_countdown:
		_has_match_start_countdown_started = true

		# Calculate match start countdown end frame
		# relative to current server frame.
		var countdown_duration := int(
			Netcode.settings.match_start_countdown_sec
			* target_network_fps
		)
		var countdown_end := (
			server_frame_index + countdown_duration
		)
		match_start_countdown_end_frame_index = countdown_end

		Netcode.log.print(
			("Starting match start countdown"
			+" (%d frames, ends at %d)")
			% [countdown_duration, countdown_end],
			NetworkLogger.CATEGORY_GAME_STATE
		)

		# Notify clients to start match start
		# countdown (they pause locally). Include
		# server frame index so clients can sync
		# their frame counter immediately.
		if is_inside_tree():
			Netcode.call_client_rpc_with_local_support(
				_client_rpc_start_match_start_countdown
					.bind(
						countdown_end,
						server_frame_index,
					))

		# Emit signal for game-specific UI.
		match_start_countdown_started.emit(countdown_end)
	else:
		# Normal unpause - notify clients.
		if Netcode.runs_server_logic and is_inside_tree():
			Netcode.call_client_rpc_with_local_support(
				_client_rpc_notify_unpause.bind(
					server_frame_index,
					_cumulative_paused_frames,
				))

	# Unpause Godot scene tree.
	if is_inside_tree():
		get_tree().paused = false

	# Emit signal for UI updates.
	pause_state_changed.emit(false, 0)

	Netcode.log.print(
		("Server unpaused at frame %d (paused "
		+"for %d frames, cumulative: %d)")
		% [server_frame_index,
		pause_duration_frames,
		_cumulative_paused_frames],
		NetworkLogger.CATEGORY_NETWORK_SYNC
	)


## Execute pause on client at server-specified frame (client-side).
func _client_execute_pause_at_server_frame(
		server_pause_frame: int,
		pause_initiator_peer_id: int,
		pause_initiator_pauses_used: int,
) -> void:
	if _is_paused:
		return

	_is_paused = true
	_pause_initiator_peer_id = pause_initiator_peer_id
	_pause_initiator_pauses_used = pause_initiator_pauses_used

	# Calculate auto-unpause time for countdown display.
	_pause_auto_unpause_time_usec = (
		Time.get_ticks_usec()
		+ int(
			Netcode.settings.max_pause_duration_sec
			* 1_000_000
		)
	)

	# Align with server's pause frame.
	server_frame_index = server_pause_frame
	_pause_start_frame_index = server_pause_frame
	_pause_start_time_usec = Time.get_ticks_usec()

	# Clean up buffer frames after pause started.
	_cleanup_buffer_after_pause()

	# Clear queued rollback.
	_queued_rollback_frame_index = 0
	_queued_rollback_cause = ""

	# Pause Godot scene tree.
	if is_inside_tree():
		get_tree().paused = true

	# Emit signal for game to handle screen transitions.
	pause_state_changed.emit(true, pause_initiator_peer_id)

	Netcode.log.print(
		"Client synchronized pause at frame %d" % server_frame_index,
		NetworkLogger.CATEGORY_NETWORK_SYNC
	)


## Execute unpause on client at server-specified frame (client-side).
func _client_execute_unpause_at_server_frame(
		server_unpause_frame: int,
		server_cumulative_paused_frames: int,
) -> void:
	if not _is_paused:
		return

	# Adopt server's pause accounting.
	_cumulative_paused_frames = server_cumulative_paused_frames

	var previous_frame := server_frame_index

	# Align frame index with server.
	server_frame_index = server_unpause_frame

	_is_paused = false
	_pause_start_frame_index = 0

	# Reset pause state variables.
	_pause_initiator_peer_id = 0
	_pause_initiator_pauses_used = 0
	_pause_auto_unpause_time_usec = 0

	# Unpause Godot scene tree.
	if is_inside_tree():
		get_tree().paused = false

	# Emit signal for game to handle screen transitions.
	pause_state_changed.emit(false, 0)

	Netcode.log.print(
		"Client synchronized unpause: frame %d->%d (paused: %d, init=%s)" % [
			previous_frame,
			server_frame_index,
			_cumulative_paused_frames,
			_is_frame_tracking_initialized,
		],
		NetworkLogger.CATEGORY_NETWORK_SYNC
	)


## Clean up rollback buffer state after pause.
func _cleanup_buffer_after_pause() -> void:
	for node in _networked_state_nodes:
		if is_instance_valid(node):
			node._cleanup_buffer_after_pause(_pause_start_frame_index)


## Reinitialize rollback buffers after a hard frame reset.
##
## When the frame index jumps backward (e.g., from 1439 to 1429), the buffers
## contain stale predicted data at the new frame indices. This method
## reinitializes buffers to default values at the new frame, preventing stale
## data from corrupting the simulation.
func reinitialize_buffers_for_hard_reset(new_frame_index: int) -> void:
	for node in _networked_state_nodes:
		if is_instance_valid(node):
			node._reinitialize_buffer_for_hard_reset(new_frame_index)


func _pre_physics_process(_delta: float) -> void:
	# Slow frame simulation: artificially delay physics ticks to
	# simulate a machine struggling to keep up.
	if (
		Netcode.condition_simulator != null
		and Netcode.condition_simulator.is_enabled
		and Netcode.condition_simulator.get_frame_delay_ms() > 0
	):
		OS.delay_msec(
			Netcode.condition_simulator.get_frame_delay_ms()
		)

	if _is_paused:
		# Still advance frame index in lobby so
		# frame-based logic (boost cooldown, coyote
		# time, jump throttle) works correctly even
		# though networking is paused. Skip during
		# matchmaking/loading to prevent frame drift
		# before NTP sync.
		if G.is_lobby_active:
			if not _is_frame_tracking_initialized:
				_initialize_frame_tracking()
			else:
				server_frame_index += 1
		return

	# Gradual slow-down: skip this physics tick to
	# let the server catch up by one frame. Mirrors
	# the gradual catch-up (extra frame per tick)
	# for the opposite direction.
	if _slowdown_frames_remaining > 0:
		_slowdown_frames_remaining -= 1
		return

	if not _is_frame_tracking_initialized:
		_initialize_frame_tracking()
		return

	# Increment frame index directly on each physics tick.
	server_frame_index += 1

	# During match start countdown, process only buffer synchronization without game logic.
	# This keeps rollback buffers in sync while preventing character movement.
	# Clients stay paused; animations still run (PROCESS_MODE_ALWAYS).
	if is_match_start_countdown_active:
		_run_network_process(true)
		return

	# Handle match start countdown end: log, unpause client tree, emit signal.
	if match_start_countdown_end_frame_index >= 0 and not _has_match_start_countdown_ended:
		Netcode.log.print(
			"Match start countdown ended at frame %d, match starting" % server_frame_index,
			NetworkLogger.CATEGORY_GAME_STATE
		)
		_has_match_start_countdown_ended = true

		# Unpause client tree (was paused when match start countdown started).
		if Netcode.is_client and is_inside_tree():
			get_tree().paused = false

		match_start_countdown_ended.emit()

	_run_network_process()

	# Gradual catch-up: process one extra frame per
	# physics tick to smoothly close small clock drift
	# gaps instead of fast-forwarding many frames at
	# once (which causes visible stutter).
	if _catchup_frames_remaining > 0:
		server_frame_index += 1
		_catchup_frames_remaining -= 1
		_run_network_process()


func _initialize_frame_tracking() -> void:
	# Frame tracking can start immediately since we use frame-based sync.
	_is_frame_tracking_initialized = true

	# Initialize to frame 0.
	# The first physics tick will increment this to 1.
	var previous_frame_index := server_frame_index
	server_frame_index = 0

	# Note: Clients track their own frame indices locally starting from 0.
	# Periodic frame index broadcasts from the server prevent drift.
	Netcode.log.print(
		"Frame tracking initialized at frame 0 (was %d)" % previous_frame_index,
		NetworkLogger.CATEGORY_NETWORK_SYNC
	)


## Registers a ReconcilableState node for frame-synchronous processing.
func add_networked_state(node: ReconcilableState) -> void:
	Netcode.log.ensure(not _networked_state_nodes.has(node), "Node already registered")
	_networked_state_nodes.append(node)


func remove_networked_state(node: ReconcilableState) -> void:
	var index := _networked_state_nodes.find(node)
	Netcode.log.ensure(index >= 0, "Node not found in registered nodes")
	_networked_state_nodes.remove_at(index)


func add_frame_processor(node: FrameProcessor) -> void:
	Netcode.log.ensure(not _frame_processor_nodes.has(node), "Node already registered")
	_frame_processor_nodes.append(node)


func remove_frame_processor(node: FrameProcessor) -> void:
	var index := _frame_processor_nodes.find(node)
	Netcode.log.ensure(index >= 0, "Node not found in registered nodes")
	_frame_processor_nodes.remove_at(index)


func is_frame_too_old_to_consider(p_frame_index: int) -> bool:
	var target_rollback_frame := p_frame_index + 1
	return target_rollback_frame < oldest_rollbackable_frame_index


## This will trigger a rollback to occur on the next _network_process.
##
## - At most one rollback will occur per _network_process loop, and the earliest
##   server_frame_index will be used.
## - The given frame index marks where the state mismatch occured that is
##   triggering this rollback.
## - The first processed frame of the rollback will be the frame _after_ the
##   mismatch.
##   - We already know that the local simulation at the mismatch resulting in
##     the wrong state, so we don't re-simulate that frame.
func queue_rollback(
	p_conflicting_frame_index: int,
	p_cause: String = "",
) -> bool:
	var target_rollback_frame := p_conflicting_frame_index + 1
	if is_frame_too_old_to_consider(p_conflicting_frame_index):
		Netcode.log.warning(
			("Rollback rejected: frame %d is "
			+"too old (oldest rollbackable: %d)")
			% [
				target_rollback_frame,
				oldest_rollbackable_frame_index,
			],
			NetworkLogger.CATEGORY_NETWORK_SYNC
		)
		return false

	# Rollback simulation would start on the next frame after the mismatch.
	if _queued_rollback_frame_index == 0:
		_queued_rollback_frame_index = target_rollback_frame
		_queued_rollback_cause = p_cause
	else:
		if target_rollback_frame < _queued_rollback_frame_index:
			_queued_rollback_cause = p_cause
		_queued_rollback_frame_index = mini(
			_queued_rollback_frame_index,
			target_rollback_frame,
		)

	return true


## For most nodes in the scene, _network_process should happen before
## _physics_process.
func _run_network_process(only_buffers := false) -> void:
	if _queued_rollback_frame_index > 0:
		if only_buffers:
			# Discard rollbacks during countdown.
			# Re-simulation would overwrite correct
			# server state in the buffer with wrong
			# values derived from default-filled
			# earlier frames.
			_queued_rollback_frame_index = 0
			_queued_rollback_cause = ""
		else:
			_rollback_and_reprocess()
			_queued_rollback_frame_index = 0
			_queued_rollback_cause = ""

	if only_buffers:
		_network_process_buffers_only()
	else:
		_network_process()


func _rollback_and_reprocess() -> void:
	var cause_str := (
		" cause=%s" % _queued_rollback_cause
		if _queued_rollback_cause != ""
		else ""
	)
	if Netcode.log.is_verbose:
		Netcode.log.verbose(
			("Starting rollback from frame %d"
			+" to frame %d%s")
			% [server_frame_index,
			_queued_rollback_frame_index,
			cause_str],
			NetworkLogger.CATEGORY_NETWORK_SYNC
		)

	var rollback_start_time_usec := Time.get_ticks_usec()

	var original_server_frame_index := server_frame_index

	server_frame_index = _queued_rollback_frame_index

	# Re-simulate all frames between the mismatch and current frame (exclusive).
	# The loop processes frames [rollback_frame, original_frame), but not the
	# original frame itself. The current frame will be re-simulated afterward in
	# the normal _run_network_process flow.
	is_resimulating = true
	var frame_count := 0
	while server_frame_index < original_server_frame_index:
		_network_process()
		server_frame_index += 1
		frame_count += 1
	is_resimulating = false

	server_frame_index = original_server_frame_index

	# Track rollback metrics.
	last_rollback_frame_count = frame_count
	last_rollback_duration_usec = Time.get_ticks_usec() - rollback_start_time_usec
	total_rollbacks += 1


## Simulate the current frame for all network-process-aware nodes.
func _network_process() -> void:
	# Remove invalid nodes (iterate backwards to avoid issues when removing).
	for i in range(_networked_state_nodes.size() - 1, -1, -1):
		var node := _networked_state_nodes[i]
		# TODO: This should not be possible, so try to figure out the underlying
		#       problem.
		if not is_instance_valid(node):
			_networked_state_nodes.remove_at(i)

	# Sync other scene state from the current network state.
	for node in _networked_state_nodes:
		node._pre_network_process()

	# Let all network-process-aware nodes handle the frame.
	for node in _networked_state_nodes:
		node._network_process()
	for node in _frame_processor_nodes:
		node._network_process()

	# Sync the current network state from other scene state.
	for node in _networked_state_nodes:
		node._post_network_process()

	# Send bundled state after all nodes have packed.
	_maybe_send_bundles()


## Process only buffer synchronization without game logic (for match start countdown).
## This keeps rollback buffers in sync between server and clients during match start countdown
## without actually simulating game logic.
func _network_process_buffers_only() -> void:
	# Remove invalid nodes (iterate backwards to avoid issues when removing).
	for i in range(_networked_state_nodes.size() - 1, -1, -1):
		var node := _networked_state_nodes[i]
		if not is_instance_valid(node):
			_networked_state_nodes.remove_at(i)

	# SKIP _pre_network_process(). During countdown, scene
	# state is set by the direct-apply path in
	# receive_network_state (line 715). Calling
	# _pre_network_process would load stale/default values
	# from the rollback buffer and overwrite the correct
	# scene positions, causing per-frame flicker between
	# spawn position and world origin.

	# SKIP _network_process() - no game logic during
	# match start countdown.

	# Update frame bookkeeping that _pre_network_process
	# normally handles, so _post_network_process packs
	# state at the correct buffer index.
	for node in _networked_state_nodes:
		node.frame_index = server_frame_index
		node.frame_authority = (
			ReconcilableState.FrameAuthority.UNKNOWN
		)

	# Pack current scene state into rollback buffers.
	# This flows one-way: scene -> buffer.
	for node in _networked_state_nodes:
		node._post_network_process()

	# Send bundled state after all nodes have packed.
	_maybe_send_bundles()


func fast_forward(new_frame_index: int) -> void:
	# Cancel slow-down since we're jumping ahead.
	_slowdown_frames_remaining = 0
	var fastforward_start_time_usec := Time.get_ticks_usec()
	var frame_count := 0

	while server_frame_index < new_frame_index:
		server_frame_index += 1
		_network_process()
		frame_count += 1

	# Track fast-forward metrics.
	last_fastforward_frame_count = frame_count
	last_fastforward_duration_usec = Time.get_ticks_usec() - fastforward_start_time_usec
	total_fastforwards += 1


## Send bundled state if bundling is active and not
## during rollback re-simulation.
func _maybe_send_bundles() -> void:
	if (
		not Netcode.is_bundled_send
		or is_resimulating
		or Netcode.state_bundler == null
	):
		return
	Netcode.state_bundler._send_bundles()
