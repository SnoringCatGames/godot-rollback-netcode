class_name PerfTracker
extends Node
## Performance tracking and server-client metric synchronization.
##
## PerfTracker is responsible for:
## - Tracking local performance metrics (FPS, rollback, fastforward, ping)
## - Calculating per-second rates and min/max windows
## - Registering custom Performance monitors (only in preview mode)
## - Server: Collecting and broadcasting perf state to clients via RPC
## - Client: Receiving and storing server perf state
##
## This class handles logic and networking. UI rendering is handled by
## PerfTrackerPanel. Accessed via Netcode.perf_tracker singleton.

# --- Server perf sync constants ---

## Interval for syncing server performance metrics to clients (seconds).
const PERF_SYNC_INTERVAL_SEC := 15.0

## Initial delay before first performance sync after match starts (seconds).
## Gives server time to stabilize metrics before first sync.
const PERF_SYNC_INITIAL_DELAY_SEC := 5.0

## Interval for periodic metric logging (seconds).
const METRICS_LOG_INTERVAL_SEC := 15.0

# --- Performance warning threshold constants ---

const _SLOW_NETWORK_RTT_THRESHOLD_SEC := 0.1 # 100ms
const _LARGE_FASTFORWARD_THRESHOLD := 2
const _HIGH_FASTFORWARD_RATE_THRESHOLD := 0.2
const _SLOW_RENDER_FPS := 30
## Margin below target physics FPS that triggers a
## warning. Dynamic so it works at both 60fps and
## 30fps. E.g. at 30fps target, threshold is 20.
const _SLOW_PHYSICS_FPS_MARGIN := 10
## Margin below target physics FPS for network FPS
## warning. Network FPS should track physics FPS.
const _SLOW_NETWORK_FPS_MARGIN := 10
const _WARNING_THROTTLE_SEC := 5.0

# --- Tracking window constants ---

const _ROLLBACK_TRACKING_WINDOW_SEC := 60.0
const _FASTFORWARD_TRACKING_WINDOW_SEC := 60.0
const _MAX_MIN_TRACKING_WINDOW_SEC := 10.0
const _FPS_TRACKING_WINDOW_SEC := 1.0
# Minimum frames before FPS calculation is
# considered reliable. Prevents false low-FPS
# warnings from single-frame jitter right after
# window reset (e.g. 1 frame / 0.021s = 47.6).
const _MIN_FRAMES_FOR_FPS_WARNING := 10

# --- Tracking window state ---

var _render_frame_count := 0
var _render_window_start_time := 0.0
var _physics_frame_count := 0
var _physics_window_start_time := 0.0
var _network_frame_count := 0
var _network_window_start_time := 0.0
var _rollback_count_in_window := 0
var _rollback_window_start_time := 0.0
var _last_total_rollbacks := 0
var _fastforward_count_in_window := 0
var _fastforward_window_start_time := 0.0
var _last_total_fastforwards := 0

# --- Current local metric values ---

var _current_render_fps := 0.0
var _current_physics_fps := 0.0
var _current_network_fps := 0.0
var _current_network_ping_ms := 0.0
var _current_rollbacks_per_sec := 0.0
var _current_last_rollback_duration_ms := 0.0
var _current_last_rollback_frames := 0
var _current_fastforwards_per_sec := 0.0
var _current_last_fastforward_duration_ms := 0.0
var _current_last_fastforward_frames := 0
var _current_rtt_jitter_ms := 0.0
var _current_input_delay_frames := 0
var _current_packet_loss_pct := 0.0

# Packet loss tracking (frame_index gap detection).
var _last_received_state_frame_index := -1
var _frames_received_in_window := 0
var _frames_expected_in_window := 0
var _loss_window_start_time := 0.0
const _LOSS_WINDOW_SEC := 5.0

# --- Min/max metric tracking (periodic window) ---

var _max_min_window_start_time := 0.0
var _min_render_fps_in_window := INF
var _min_physics_fps_in_window := INF
var _min_network_fps_in_window := INF
var _max_network_ping_in_window := 0.0
var _max_rollbacks_per_sec_in_window := 0.0
var _max_last_rollback_duration_in_window := 0.0
var _max_last_rollback_frames_in_window := 0
var _max_fastforwards_per_sec_in_window := 0.0
var _max_last_fastforward_duration_in_window := 0.0
var _max_last_fastforward_frames_in_window := 0
var _max_rtt_jitter_in_window := 0.0
var _max_input_delay_in_window := 0
var _max_packet_loss_in_window := 0.0

# --- Server metrics (client-only, received via RPC) ---

var _server_perf_state := {
	"physics_fps": 0.0,
	"min_physics_fps": INF,
	"network_fps": 0.0,
	"min_network_fps": INF,
	"rollbacks_per_sec": 0.0,
	"max_rollbacks_per_sec": 0.0,
	"last_rollback_duration_ms": 0.0,
	"max_last_rollback_duration_ms": 0.0,
	"last_rollback_frames": 0,
	"max_last_rollback_frames": 0,
	"fastforwards_per_sec": 0.0,
	"max_fastforwards_per_sec": 0.0,
	"last_fastforward_duration_ms": 0.0,
	"max_last_fastforward_duration_ms": 0.0,
	"last_fastforward_frames": 0,
	"max_last_fastforward_frames": 0,
}

# --- Throttled warning callables ---

var _throttled_warn_render_fps: Callable
var _throttled_warn_physics_fps: Callable
var _throttled_warn_network_fps: Callable
var _throttled_warn_network_rtt: Callable
var _throttled_warn_large_fastforward: Callable
var _throttled_warn_high_fastforward_rate: Callable

# --- Optional callbacks ---

## Optional callback to check if the game is ready for performance tracking.
## If not provided, always returns true (always ready).
## Signature: func() -> bool
var is_ready_callback: Callable

# --- Lifecycle methods ---


func _ready() -> void:
	if TestEnvironmentDetector.is_running_in_test_env(self ):
		return

	Netcode.log.print("PerfTracker")

	# Register custom performance monitors (only in preview mode for performance).
	if Netcode.is_preview:
		_register_custom_monitors()

	# Set up throttled warning functions.
	_throttled_warn_render_fps = Netcode.time.throttle(
		_log_render_fps_warning,
		_WARNING_THROTTLE_SEC,
	)
	_throttled_warn_physics_fps = Netcode.time.throttle(
		_log_physics_fps_warning,
		_WARNING_THROTTLE_SEC,
	)
	_throttled_warn_network_fps = Netcode.time.throttle(
		_log_network_fps_warning,
		_WARNING_THROTTLE_SEC,
	)
	_throttled_warn_network_rtt = Netcode.time.throttle(
		_log_network_rtt_warning,
		_WARNING_THROTTLE_SEC,
	)
	_throttled_warn_large_fastforward = Netcode.time.throttle(
		_log_large_fastforward_warning,
		_WARNING_THROTTLE_SEC,
	)
	_throttled_warn_high_fastforward_rate = Netcode.time.throttle(
		_log_high_fastforward_rate_warning,
		_WARNING_THROTTLE_SEC,
	)

	# Start periodic metric logging.
	if Netcode.settings.tracking_perf:
		Netcode.time.set_interval(
			_log_metrics_periodically,
			METRICS_LOG_INTERVAL_SEC,
		)

	# Connect to local authority signals for network FPS tracking.
	Netcode.local_authority_added.connect(_on_local_authority_added)
	Netcode.local_authority_removed.connect(_on_local_authority_removed)

	# Server: Start periodic sync to clients.
	if Netcode.is_server:
		Netcode.time.set_timeout(
			_start_perf_sync_interval,
			PERF_SYNC_INITIAL_DELAY_SEC,
		)

		# Connect to peer connections for immediate sync on late-join.
		multiplayer.peer_connected.connect(_on_peer_connected)


func _process(_delta: float) -> void:
	if TestEnvironmentDetector.is_running_in_test_env(self ):
		return

	_calculate_render_fps()
	_check_and_reset_max_min_window()
	if _current_render_fps > 0.0:
		_min_render_fps_in_window = min(
			_min_render_fps_in_window,
			_current_render_fps,
		)

	# Check for slow render FPS and log warning.
	if (
		_current_render_fps > 0.0
		and _current_render_fps < _SLOW_RENDER_FPS
		and _render_frame_count >= _MIN_FRAMES_FOR_FPS_WARNING
		and _is_ready()
	):
		_throttled_warn_render_fps.call([_current_render_fps])


func _physics_process(_delta: float) -> void:
	if TestEnvironmentDetector.is_running_in_test_env(self ):
		return

	_calculate_physics_fps()
	if _current_physics_fps > 0.0:
		_min_physics_fps_in_window = min(
			_min_physics_fps_in_window,
			_current_physics_fps,
		)

	# Check for slow physics FPS and log warning.
	# Require enough samples to avoid false warnings
	# from single-frame jitter after window reset.
	var physics_threshold := (
		Netcode.frame_driver.target_network_fps
		- _SLOW_PHYSICS_FPS_MARGIN
	) if Netcode.frame_driver else 50.0
	if (
		_current_physics_fps > 0.0
		and _current_physics_fps < physics_threshold
		and _physics_frame_count >= _MIN_FRAMES_FOR_FPS_WARNING
		and _is_ready()
	):
		_throttled_warn_physics_fps.call(
			[_current_physics_fps, physics_threshold],
		)

	_update_network_ping()
	_update_rollback_metrics()
	_update_fastforward_metrics()

# --- Signal handlers ---


func _on_local_authority_added(
	input_from_client: ReconcilableState,
) -> void:
	# Wait a tick to ensure state_from_server is populated.
	await get_tree().process_frame

	if not is_instance_valid(input_from_client):
		return
	if not is_instance_valid(input_from_client.state_from_server):
		return

	input_from_client.state_from_server \
		.received_network_state.connect(
			_character_state_from_server_updated,
		)


func _on_local_authority_removed(
		input_from_client: ReconcilableState,
) -> void:
	if (
		is_instance_valid(input_from_client)
		and is_instance_valid(
			input_from_client.state_from_server)
		and input_from_client.state_from_server
			.received_network_state.is_connected(
				_character_state_from_server_updated)
	):
		input_from_client.state_from_server \
			.received_network_state.disconnect(
				_character_state_from_server_updated,
			)


func _on_peer_connected(peer_id: int) -> void:
	if not Netcode.is_server:
		return
	if not _is_ready():
		return

	# Send immediate sync to newly connected client.
	var perf_state := _server_collect_perf_state()
	_client_rpc_receive_server_perf_state.rpc_id(peer_id, perf_state)


func _character_state_from_server_updated(
		state_frame_index: int,
) -> void:
	_calculate_network_fps()
	if _current_network_fps > 0.0:
		_min_network_fps_in_window = min(
			_min_network_fps_in_window,
			_current_network_fps,
		)

	_update_packet_loss(state_frame_index)

	# Check for slow network FPS and log warning.
	var network_threshold := (
		Netcode.frame_driver.target_network_fps
		- _SLOW_NETWORK_FPS_MARGIN
	) if Netcode.frame_driver else 30.0
	if (
		_current_network_fps > 0.0
		and _current_network_fps < network_threshold
		and _network_frame_count >= _MIN_FRAMES_FOR_FPS_WARNING
		and _is_ready()
	):
		_throttled_warn_network_fps.call(
			[_current_network_fps, network_threshold],
		)


# --- Helper methods ---


## Check if the game is ready for performance tracking.
## Uses optional callback if provided, otherwise always returns true.
func _is_ready() -> bool:
	if is_ready_callback.is_valid():
		return is_ready_callback.call()
	return true


# --- Server-side RPC methods ---


func _start_perf_sync_interval() -> void:
	Netcode.log.check(Netcode.is_server, "Must be server")

	# Wait for level to be fully loaded before starting sync.
	if not _is_ready():
		# Retry after 1 second if not ready.
		Netcode.time.set_timeout(_start_perf_sync_interval, 1.0)
		return

	# Start periodic sync.
	Netcode.time.set_interval(
		_server_sync_perf_to_clients,
		PERF_SYNC_INTERVAL_SEC,
	)


func _server_sync_perf_to_clients() -> void:
	Netcode.log.check(Netcode.is_server, "Must be server")

	var perf_state := _server_collect_perf_state()
	_client_rpc_receive_server_perf_state.rpc(perf_state)


func _server_collect_perf_state() -> Dictionary:
	Netcode.log.check(Netcode.is_server, "Must be server")

	return {
		"physics_fps": _current_physics_fps,
		"min_physics_fps": _min_physics_fps_in_window,
		"network_fps": _current_physics_fps, # Use physics FPS as proxy
		"min_network_fps": _min_physics_fps_in_window,
		"rollbacks_per_sec": _current_rollbacks_per_sec,
		"max_rollbacks_per_sec": _max_rollbacks_per_sec_in_window,
		"last_rollback_duration_ms": _current_last_rollback_duration_ms,
		"max_last_rollback_duration_ms": _max_last_rollback_duration_in_window,
		"last_rollback_frames": _current_last_rollback_frames,
		"max_last_rollback_frames": _max_last_rollback_frames_in_window,
		"fastforwards_per_sec": _current_fastforwards_per_sec,
		"max_fastforwards_per_sec": _max_fastforwards_per_sec_in_window,
		"last_fastforward_duration_ms": _current_last_fastforward_duration_ms,
		"max_last_fastforward_duration_ms": _max_last_fastforward_duration_in_window,
		"last_fastforward_frames": _current_last_fastforward_frames,
		"max_last_fastforward_frames": _max_last_fastforward_frames_in_window,
	}

# --- Client-side RPC methods ---


@rpc("authority", "call_remote", "reliable", NetworkConnector.RPC_CHANNEL_DEBUG)
func _client_rpc_receive_server_perf_state(server_perf_state: Dictionary) -> void:
	Netcode.log.check(not Netcode.is_server, "Must be client")

	# Validate expected keys.
	var required_keys := [
		"physics_fps",
		"min_physics_fps",
		"network_fps",
		"min_network_fps",
		"rollbacks_per_sec",
		"max_rollbacks_per_sec",
		"last_rollback_duration_ms",
		"max_last_rollback_duration_ms",
		"last_rollback_frames",
		"max_last_rollback_frames",
		"fastforwards_per_sec",
		"max_fastforwards_per_sec",
		"last_fastforward_duration_ms",
		"max_last_fastforward_duration_ms",
		"last_fastforward_frames",
		"max_last_fastforward_frames",
	]

	for key in required_keys:
		if not server_perf_state.has(key):
			Netcode.log.warning("Server perf state missing key: %s" % key)
			return

	_server_perf_state = server_perf_state

# --- Public getters for client metrics ---


func get_client_render_fps() -> float:
	return _current_render_fps


func get_client_physics_fps() -> float:
	return _current_physics_fps


func get_client_network_fps() -> float:
	return _current_network_fps


func get_client_network_ping_ms() -> float:
	return _current_network_ping_ms


func get_client_rollbacks_per_sec() -> float:
	return _current_rollbacks_per_sec


func get_client_last_rollback_duration_ms() -> float:
	return _current_last_rollback_duration_ms


func get_client_last_rollback_frames() -> int:
	return _current_last_rollback_frames


func get_client_fastforwards_per_sec() -> float:
	return _current_fastforwards_per_sec


func get_client_last_fastforward_duration_ms() -> float:
	return _current_last_fastforward_duration_ms


func get_client_last_fastforward_frames() -> int:
	return _current_last_fastforward_frames


func get_min_render_fps() -> float:
	return _min_render_fps_in_window


func get_min_physics_fps() -> float:
	return _min_physics_fps_in_window


func get_min_network_fps() -> float:
	return _min_network_fps_in_window


func get_max_network_ping_ms() -> float:
	return _max_network_ping_in_window


func get_max_rollbacks_per_sec() -> float:
	return _max_rollbacks_per_sec_in_window


func get_max_last_rollback_duration_ms() -> float:
	return _max_last_rollback_duration_in_window


func get_max_last_rollback_frames() -> int:
	return _max_last_rollback_frames_in_window


func get_max_fastforwards_per_sec() -> float:
	return _max_fastforwards_per_sec_in_window


func get_max_last_fastforward_duration_ms() -> float:
	return _max_last_fastforward_duration_in_window


func get_max_last_fastforward_frames() -> int:
	return _max_last_fastforward_frames_in_window


func get_client_rtt_jitter_ms() -> float:
	return _current_rtt_jitter_ms


func get_max_rtt_jitter_ms() -> float:
	return _max_rtt_jitter_in_window


func get_client_input_delay_frames() -> int:
	return _current_input_delay_frames


func get_max_input_delay_frames() -> int:
	return _max_input_delay_in_window


func get_client_packet_loss_pct() -> float:
	return _current_packet_loss_pct


func get_max_packet_loss_pct() -> float:
	return _max_packet_loss_in_window

# --- Public getters for server metrics ---


func get_server_physics_fps() -> float:
	return _server_perf_state.physics_fps


func get_server_network_fps() -> float:
	return _server_perf_state.network_fps


func get_server_rollbacks_per_sec() -> float:
	return _server_perf_state.rollbacks_per_sec


func get_server_last_rollback_duration_ms() -> float:
	return _server_perf_state.last_rollback_duration_ms


func get_server_last_rollback_frames() -> int:
	return _server_perf_state.last_rollback_frames


func get_server_fastforwards_per_sec() -> float:
	return _server_perf_state.fastforwards_per_sec


func get_server_last_fastforward_duration_ms() -> float:
	return _server_perf_state.last_fastforward_duration_ms


func get_server_last_fastforward_frames() -> int:
	return _server_perf_state.last_fastforward_frames


func get_server_min_physics_fps() -> float:
	return _server_perf_state.min_physics_fps


func get_server_min_network_fps() -> float:
	return _server_perf_state.min_network_fps


func get_server_max_rollbacks_per_sec() -> float:
	return _server_perf_state.max_rollbacks_per_sec


func get_server_max_last_rollback_duration_ms() -> float:
	return _server_perf_state.max_last_rollback_duration_ms


func get_server_max_last_rollback_frames() -> int:
	return _server_perf_state.max_last_rollback_frames


func get_server_max_fastforwards_per_sec() -> float:
	return _server_perf_state.max_fastforwards_per_sec


func get_server_max_last_fastforward_duration_ms() -> float:
	return _server_perf_state.max_last_fastforward_duration_ms


func get_server_max_last_fastforward_frames() -> int:
	return _server_perf_state.max_last_fastforward_frames

# --- Periodic logging ---


func _log_metrics_periodically() -> void:
	if not Netcode.settings.tracking_perf:
		return

	Netcode.log.print(
		(
			"PERF: FPS[P:%.1f R:%.1f N:%.1f] "
			+"PING:%.1fms JITTER:%.1fms "
			+"LOSS:%.0f%% DELAY:%df "
			+"RB[/s:%.1f last:%.2fms/%df] "
			+"FF[/s:%.1f last:%.2fms/%df]"
		) % [
			_current_physics_fps,
			_current_render_fps,
			_current_network_fps,
			_current_network_ping_ms,
			_current_rtt_jitter_ms,
			_current_packet_loss_pct,
			_current_input_delay_frames,
			_current_rollbacks_per_sec,
			_current_last_rollback_duration_ms,
			_current_last_rollback_frames,
			_current_fastforwards_per_sec,
			_current_last_fastforward_duration_ms,
			_current_last_fastforward_frames,
		],
		NetworkLogger.CATEGORY_CORE_SYSTEMS,
	)

# --- Performance warning logs ---


func _log_render_fps_warning(avg_fps: float) -> void:
	Netcode.log.warning(
		("Slow render FPS: %.1f "
		+ "(threshold: %d)")
		% [avg_fps, _SLOW_RENDER_FPS],
		NetworkLogger.CATEGORY_CORE_SYSTEMS,
	)


func _log_physics_fps_warning(
		avg_fps: float,
		threshold: float,
) -> void:
	Netcode.log.warning(
		("Slow physics FPS: %.1f "
		+ "(threshold: %d)")
		% [avg_fps, roundi(threshold)],
		NetworkLogger.CATEGORY_CORE_SYSTEMS,
	)


func _log_network_fps_warning(
		avg_fps: float,
		threshold: float,
) -> void:
	Netcode.log.warning(
		("Slow network FPS: %.1f "
		+ "(threshold: %d)")
		% [avg_fps, roundi(threshold)],
		NetworkLogger.CATEGORY_CORE_SYSTEMS,
	)


func _log_network_rtt_warning(rtt_msec: float) -> void:
	Netcode.log.warning(
		("Slow network RTT: %.1fms "
		+ "(threshold: %.0fms)")
		% [rtt_msec,
		_SLOW_NETWORK_RTT_THRESHOLD_SEC * 1000.0],
		NetworkLogger.CATEGORY_CORE_SYSTEMS,
	)


func _log_large_fastforward_warning(frame_count: int) -> void:
	# Suppress warning during grace period after frame reset (expected during reconnection).
	if Netcode.frame_driver.is_in_sync_grace_period:
		return
	Netcode.log.warning(
		("Large fast-forward: %d frames "
		+ "(threshold: %d)")
		% [frame_count,
		_LARGE_FASTFORWARD_THRESHOLD],
		NetworkLogger.CATEGORY_CORE_SYSTEMS,
	)


func _log_high_fastforward_rate_warning(rate: float) -> void:
	Netcode.log.warning(
		("High fast-forward rate: %.2f/sec "
		+ "(threshold: %.1f)")
		% [rate,
		_HIGH_FASTFORWARD_RATE_THRESHOLD],
		NetworkLogger.CATEGORY_CORE_SYSTEMS,
	)

# --- Private metric calculation helpers ---


func _calculate_render_fps() -> void:
	var current_time: float = Time.get_ticks_msec() / 1000.0

	# Initialize window on first call.
	if _render_window_start_time == 0.0:
		_render_window_start_time = current_time

	_render_frame_count += 1

	# Calculate FPS over the tracking window.
	var window_duration: float = current_time - _render_window_start_time
	if window_duration > 0.0:
		_current_render_fps = _render_frame_count / window_duration
	else:
		_current_render_fps = 0.0

	# Reset window after full duration.
	if window_duration >= _FPS_TRACKING_WINDOW_SEC:
		_render_frame_count = 0
		_render_window_start_time = current_time


func _calculate_physics_fps() -> void:
	var current_time: float = Time.get_ticks_msec() / 1000.0

	# Initialize window on first call.
	if _physics_window_start_time == 0.0:
		_physics_window_start_time = current_time

	_physics_frame_count += 1

	# Calculate FPS over the tracking window.
	var window_duration: float = current_time - _physics_window_start_time
	if window_duration > 0.0:
		_current_physics_fps = _physics_frame_count / window_duration
	else:
		_current_physics_fps = 0.0

	# Reset window after full duration.
	if window_duration >= _FPS_TRACKING_WINDOW_SEC:
		_physics_frame_count = 0
		_physics_window_start_time = current_time


func _calculate_network_fps() -> void:
	var current_time: float = Time.get_ticks_msec() / 1000.0

	# Initialize window on first call.
	if _network_window_start_time == 0.0:
		_network_window_start_time = current_time

	_network_frame_count += 1

	# Calculate FPS over the tracking window.
	var window_duration: float = current_time - _network_window_start_time
	if window_duration > 0.0:
		_current_network_fps = _network_frame_count / window_duration
	else:
		_current_network_fps = 0.0

	# Reset window after full duration.
	if window_duration >= _FPS_TRACKING_WINDOW_SEC:
		_network_frame_count = 0
		_network_window_start_time = current_time


func _update_network_ping() -> void:
	# Get RTT from FrameIndexSynchronizer.
	if Netcode.frame_sync != null:
		_current_network_ping_ms = Netcode.frame_sync.rtt_usec / 1000.0
	else:
		_current_network_ping_ms = 0.0

	_max_network_ping_in_window = max(
		_max_network_ping_in_window,
		_current_network_ping_ms,
	)

	# RTT jitter.
	if Netcode.frame_sync != null:
		_current_rtt_jitter_ms = (
			Netcode.frame_sync.rtt_jitter_usec / 1000.0
		)
	else:
		_current_rtt_jitter_ms = 0.0
	_max_rtt_jitter_in_window = max(
		_max_rtt_jitter_in_window,
		_current_rtt_jitter_ms,
	)

	# Input delay.
	if Netcode.frame_sync != null:
		_current_input_delay_frames = (
			Netcode.frame_sync.input_delay_frames
		)
	else:
		_current_input_delay_frames = 0
	_max_input_delay_in_window = max(
		_max_input_delay_in_window,
		_current_input_delay_frames,
	)

	# Check for high network ping and log warning.
	if (
		_current_network_ping_ms > _SLOW_NETWORK_RTT_THRESHOLD_SEC * 1000.0
		and _is_ready()
	):
		_throttled_warn_network_rtt.call([_current_network_ping_ms])


func _update_packet_loss(state_frame_index: int) -> void:
	if _last_received_state_frame_index < 0:
		# First state -- initialize tracking.
		_last_received_state_frame_index = state_frame_index
		_loss_window_start_time = Time.get_ticks_msec() / 1000.0
		return

	# Only count forward-progressing frames (ignore out-of-order
	# or duplicate deliveries).
	if state_frame_index <= _last_received_state_frame_index:
		return

	var gap := state_frame_index - _last_received_state_frame_index
	_frames_expected_in_window += gap
	_frames_received_in_window += 1
	_last_received_state_frame_index = state_frame_index

	# Check if window has elapsed.
	var current_time := Time.get_ticks_msec() / 1000.0
	if current_time - _loss_window_start_time < _LOSS_WINDOW_SEC:
		return

	# Compute loss rate for completed window.
	if _frames_expected_in_window > 0:
		var delivery_rate := (
			float(_frames_received_in_window)
			/ _frames_expected_in_window
		)
		_current_packet_loss_pct = clampf(
			(1.0 - delivery_rate) * 100.0, 0.0, 100.0
		)
	else:
		_current_packet_loss_pct = 0.0

	_max_packet_loss_in_window = max(
		_max_packet_loss_in_window,
		_current_packet_loss_pct,
	)

	# Reset for next window.
	_frames_received_in_window = 0
	_frames_expected_in_window = 0
	_loss_window_start_time = current_time


func _update_rollback_metrics() -> void:
	var state := {
		"window_start_time": _rollback_window_start_time,
		"count_in_window": _rollback_count_in_window,
		"last_total": _last_total_rollbacks,
	}

	_current_rollbacks_per_sec = _calculate_events_per_sec(
		Netcode.frame_driver.total_rollbacks,
		state,
		_ROLLBACK_TRACKING_WINDOW_SEC,
	)

	_rollback_window_start_time = state.window_start_time
	_rollback_count_in_window = state.count_in_window
	_last_total_rollbacks = state.last_total

	# Calculate last rollback metrics.
	_current_last_rollback_duration_ms = (
		Netcode.frame_driver.last_rollback_duration_usec / 1000.0
	)
	_current_last_rollback_frames = (
		Netcode.frame_driver.last_rollback_frame_count
	)

	# Update max tracking.
	_max_rollbacks_per_sec_in_window = max(
		_max_rollbacks_per_sec_in_window,
		_current_rollbacks_per_sec,
	)
	_max_last_rollback_duration_in_window = max(
		_max_last_rollback_duration_in_window,
		_current_last_rollback_duration_ms,
	)
	_max_last_rollback_frames_in_window = max(
		_max_last_rollback_frames_in_window,
		_current_last_rollback_frames,
	)


func _update_fastforward_metrics() -> void:
	var state := {
		"window_start_time": _fastforward_window_start_time,
		"count_in_window": _fastforward_count_in_window,
		"last_total": _last_total_fastforwards,
	}

	_current_fastforwards_per_sec = _calculate_events_per_sec(
		Netcode.frame_driver.total_fastforwards,
		state,
		_FASTFORWARD_TRACKING_WINDOW_SEC,
	)

	_fastforward_window_start_time = state.window_start_time
	_fastforward_count_in_window = state.count_in_window
	_last_total_fastforwards = state.last_total

	# Calculate last fastforward metrics.
	_current_last_fastforward_duration_ms = (
		Netcode.frame_driver.last_fastforward_duration_usec / 1000.0
	)
	_current_last_fastforward_frames = (
		Netcode.frame_driver.last_fastforward_frame_count
	)

	# Update max tracking.
	_max_fastforwards_per_sec_in_window = max(
		_max_fastforwards_per_sec_in_window,
		_current_fastforwards_per_sec,
	)
	_max_last_fastforward_duration_in_window = max(
		_max_last_fastforward_duration_in_window,
		_current_last_fastforward_duration_ms,
	)
	_max_last_fastforward_frames_in_window = max(
		_max_last_fastforward_frames_in_window,
		_current_last_fastforward_frames,
	)

	# Check for large fastforward and log warning.
	if (
		_current_last_fastforward_frames >= _LARGE_FASTFORWARD_THRESHOLD
		and _is_ready()
	):
		_throttled_warn_large_fastforward.call([_current_last_fastforward_frames])

	# Check for high fastforward rate and log warning.
	if (
		_current_fastforwards_per_sec > _HIGH_FASTFORWARD_RATE_THRESHOLD
		and _is_ready()
	):
		_throttled_warn_high_fastforward_rate.call([_current_fastforwards_per_sec])


func _calculate_events_per_sec(
		current_total: int,
		state: Dictionary,
		tracking_window_sec: float,
) -> float:
	var current_time: float = Time.get_ticks_msec() / 1000.0

	# Initialize window on first call.
	if state.window_start_time == 0.0:
		state.window_start_time = current_time
		state.last_total = current_total

	# Update event count in current window.
	var new_events: int = current_total - state.last_total
	state.count_in_window += new_events
	state.last_total = current_total

	# Calculate events per second over the tracking window.
	var window_duration: float = current_time - state.window_start_time
	var events_per_sec: float
	if window_duration > 0.0:
		events_per_sec = state.count_in_window / window_duration
	else:
		events_per_sec = 0.0

	# Reset window after full duration.
	if window_duration >= tracking_window_sec:
		state.count_in_window = 0
		state.window_start_time = current_time

	return events_per_sec


func _check_and_reset_max_min_window() -> void:
	var current_time := Time.get_ticks_msec() / 1000.0

	if _max_min_window_start_time == 0.0:
		_max_min_window_start_time = current_time

	var window_duration := current_time - _max_min_window_start_time
	if window_duration >= _MAX_MIN_TRACKING_WINDOW_SEC:
		_min_render_fps_in_window = INF
		_min_physics_fps_in_window = INF
		_min_network_fps_in_window = INF
		_max_network_ping_in_window = 0.0
		_max_rollbacks_per_sec_in_window = 0.0
		_max_last_rollback_duration_in_window = 0.0
		_max_last_rollback_frames_in_window = 0
		_max_fastforwards_per_sec_in_window = 0.0
		_max_last_fastforward_duration_in_window = 0.0
		_max_last_fastforward_frames_in_window = 0
		_max_rtt_jitter_in_window = 0.0
		_max_input_delay_in_window = 0
		_max_packet_loss_in_window = 0.0
		_max_min_window_start_time = current_time

# --- Custom monitor registration ---


func _register_custom_monitors() -> void:
	Performance.add_custom_monitor(
		"networking/render_fps",
		func(): return _current_render_fps,
	)
	Performance.add_custom_monitor(
		"networking/physics_fps",
		func(): return _current_physics_fps,
	)
	Performance.add_custom_monitor(
		"networking/network_fps",
		func(): return _current_network_fps,
	)
	Performance.add_custom_monitor(
		"networking/network_ping_ms",
		func(): return _current_network_ping_ms,
	)
	Performance.add_custom_monitor(
		"networking/rollbacks_per_sec",
		func(): return _current_rollbacks_per_sec,
	)
	Performance.add_custom_monitor(
		"networking/last_rollback_duration_ms",
		func(): return _current_last_rollback_duration_ms,
	)
	Performance.add_custom_monitor(
		"networking/last_rollback_frames",
		func(): return _current_last_rollback_frames,
	)
	Performance.add_custom_monitor(
		"networking/fastforwards_per_sec",
		func(): return _current_fastforwards_per_sec,
	)
	Performance.add_custom_monitor(
		"networking/last_fastforward_duration_ms",
		func(): return _current_last_fastforward_duration_ms,
	)
	Performance.add_custom_monitor(
		"networking/last_fastforward_frames",
		func(): return _current_last_fastforward_frames,
	)
	Performance.add_custom_monitor(
		"networking/min_render_fps",
		func(): return _min_render_fps_in_window,
	)
	Performance.add_custom_monitor(
		"networking/min_physics_fps",
		func(): return _min_physics_fps_in_window,
	)
	Performance.add_custom_monitor(
		"networking/min_network_fps",
		func(): return _min_network_fps_in_window,
	)
	Performance.add_custom_monitor(
		"networking/max_network_ping_ms",
		func(): return _max_network_ping_in_window,
	)
	Performance.add_custom_monitor(
		"networking/max_rollbacks_per_sec",
		func(): return _max_rollbacks_per_sec_in_window,
	)
	Performance.add_custom_monitor(
		"networking/max_last_rollback_duration_ms",
		func(): return _max_last_rollback_duration_in_window,
	)
	Performance.add_custom_monitor(
		"networking/max_last_rollback_frames",
		func(): return _max_last_rollback_frames_in_window,
	)
	Performance.add_custom_monitor(
		"networking/max_fastforwards_per_sec",
		func(): return _max_fastforwards_per_sec_in_window,
	)
	Performance.add_custom_monitor(
		"networking/max_last_fastforward_duration_ms",
		func(): return _max_last_fastforward_duration_in_window,
	)
	Performance.add_custom_monitor(
		"networking/max_last_fastforward_frames",
		func(): return _max_last_fastforward_frames_in_window,
	)
	Performance.add_custom_monitor(
		"networking/rtt_jitter_ms",
		func(): return _current_rtt_jitter_ms,
	)
	Performance.add_custom_monitor(
		"networking/max_rtt_jitter_ms",
		func(): return _max_rtt_jitter_in_window,
	)
	Performance.add_custom_monitor(
		"networking/input_delay_frames",
		func(): return _current_input_delay_frames,
	)
	Performance.add_custom_monitor(
		"networking/max_input_delay_frames",
		func(): return _max_input_delay_in_window,
	)
	Performance.add_custom_monitor(
		"networking/packet_loss_pct",
		func(): return _current_packet_loss_pct,
	)
	Performance.add_custom_monitor(
		"networking/max_packet_loss_pct",
		func(): return _max_packet_loss_in_window,
	)
