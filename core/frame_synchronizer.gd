class_name FrameSynchronizer
extends Node
## Synchronizes frame indices between server and clients using NTP-like
## protocol.
##
## Uses a ping/pong mechanism to simultaneously measure round-trip time (RTT)
## and sync frame indices. The server includes its current frame index in the
## pong response, eliminating the need for separate frame broadcasts.
##
## Combined NTP + Frame Sync Protocol:
## 1. Client sends ping with client timestamp (t1) every second.
## 2. Server receives ping at t2, immediately sends pong with:
##    - t1 (client send time)
##    - t2 (server receive time)
##    - t3 (server send time)
##    - current_frame (server's frame index at t3)
## 3. Client receives pong at t4.
## 4. Client calculates RTT = (t4 - t1) - (t3 - t2).
## 5. Client estimates frames elapsed during transmission from t3 to t4.
## 6. Client estimates current server frame and corrects drift if needed.

const _MIN_DRIFT_THRESHOLD_FRAMES := 2
const PING_INTERVAL_SEC := 3.0 # Ping server every 3 seconds.
const RTT_SMOOTHING_FACTOR := 0.2 # Exponential moving average weight.
const _MAX_RTT_SAMPLES := 10 # Jitter window size.
# Minimum time between consecutive hard resets. Prevents a
# feedback loop where repeated resets discard valid state
# before it can stabilize.
const _HARD_RESET_COOLDOWN_USEC := 3_000_000 # 3 seconds.

# Burst mode: send pings more frequently after reset for
# faster initial RTT establishment and frame sync.
const _BURST_PING_INTERVAL_SEC := 0.5
const _BURST_PING_COUNT := 6 # Send 6 burst pings (3 seconds).

# Maximum drift (in frames) that uses gradual catch-up
# (one extra frame per tick) instead of instant
# fast-forward. Drifts above this threshold still use
# instant fast-forward for large desynchronizations.
const _GRADUAL_CATCHUP_MAX_FRAMES := 10

# Network timing derived from FrameDriver config.
## Falls back to 1/60 before Netcode.frame_driver
## is initialized (e.g., during early _ready).
var target_network_time_step_sec: float:
	get:
		return (
			Netcode.frame_driver.target_network_time_step_sec if
			Netcode.frame_driver else
			1.0 / 60.0
		)

var _time_since_last_ping_sec := PING_INTERVAL_SEC
var _last_hard_reset_usec := 0
var _burst_pings_remaining := _BURST_PING_COUNT

## Minimum valid ping timestamp. Pongs from pings
## sent before this time are stale and discarded.
## Set when an external frame sync (e.g. countdown
## RPC) authoritatively sets the frame index, so
## stale burst pongs don't override it.
var _min_valid_ping_time_usec := 0

# RTT tracking (in microseconds).
var _smoothed_rtt_usec := 0
var _is_rtt_initialized := false
var _raw_rtt_samples: Array[int] = []

## Returns the smoothed round-trip time in microseconds.
var rtt_usec: float:
	get:
		return _smoothed_rtt_usec

## Returns RTT jitter as mean absolute deviation from smoothed RTT
## (in microseconds).
var rtt_jitter_usec: float:
	get:
		if _raw_rtt_samples.is_empty():
			return 0.0
		var total_deviation := 0.0
		for sample in _raw_rtt_samples:
			total_deviation += absf(
				sample - _smoothed_rtt_usec
			)
		return total_deviation / _raw_rtt_samples.size()

## Current adaptive input delay in frames, based on smoothed RTT.
## Only updated on clients; always 0 on server.
var input_delay_frames := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


## Resets sync state for a new connection.
## Ensures the first NTP ping fires immediately
## and enables burst mode for fast initial sync.
func client_reset() -> void:
	_time_since_last_ping_sec = PING_INTERVAL_SEC
	_last_hard_reset_usec = 0
	_burst_pings_remaining = _BURST_PING_COUNT
	_min_valid_ping_time_usec = 0


## Marks all in-flight pings as stale. Called
## when an external mechanism (e.g. countdown
## RPC) authoritatively syncs the frame index.
## Pongs from pings sent before this moment are
## discarded to prevent backward hard resets
## from stale burst pongs.
func invalidate_in_flight_pings() -> void:
	_min_valid_ping_time_usec = (
		Time.get_ticks_usec())


func _process(delta: float) -> void:
	# Only clients send pings. Server responds with pongs containing frame
	# index.
	if Netcode.is_client and Netcode.connector.is_connected_to_server:
		_client_process(delta)


func _client_process(delta: float) -> void:
	_time_since_last_ping_sec += delta
	var interval := (
		_BURST_PING_INTERVAL_SEC
		if _burst_pings_remaining > 0
		else PING_INTERVAL_SEC
	)
	if _time_since_last_ping_sec >= interval:
		_time_since_last_ping_sec = 0.0
		if _burst_pings_remaining > 0:
			_burst_pings_remaining -= 1
		_client_send_ping()


# -------------------------------- NTP Ping/Pong -------------------------------


func _client_send_ping() -> void:
	Netcode.check_is_client()

	var t1 := Time.get_ticks_usec()
	_server_rpc_ping.rpc_id(1, t1)


@rpc("any_peer", "call_remote", "unreliable", NetworkConnector.RPC_CHANNEL_CLOCK_SYNC)
func _server_rpc_ping(client_t1: int) -> void:
	Netcode.check_is_server()

	var t2 := Time.get_ticks_usec() # Server receive time.
	var sender_id := multiplayer.get_remote_sender_id()

	# Immediately respond with pong, including current frame index.
	var t3 := Time.get_ticks_usec() # Server send time.
	_client_rpc_pong.rpc_id(
		sender_id,
		client_t1,
		t2,
		t3,
		Netcode.frame_driver.server_frame_index,
	)


@rpc("authority", "call_remote", "unreliable", NetworkConnector.RPC_CHANNEL_CLOCK_SYNC)
func _client_rpc_pong(
		client_t1: int,
		server_t2: int,
		server_t3: int,
		server_frame_at_t3: int,
) -> void:
	Netcode.check_is_client()

	# Discard pongs from pings sent before the
	# last authoritative frame sync (e.g.
	# countdown RPC). These carry stale server
	# frame estimates that would cause incorrect
	# backward hard resets.
	if (
		_min_valid_ping_time_usec > 0
		and client_t1 < _min_valid_ping_time_usec
	):
		return

	var t4 := Time.get_ticks_usec() # Client receive time.

	# Calculate RTT: (t4 - t1) - (t3 - t2).
	var rtt_usec := (t4 - client_t1) - (server_t3 - server_t2)

	# Track raw RTT samples for jitter calculation.
	_raw_rtt_samples.append(rtt_usec)
	if _raw_rtt_samples.size() > _MAX_RTT_SAMPLES:
		_raw_rtt_samples.remove_at(0)

	# Smooth RTT using exponential moving average.
	if _is_rtt_initialized:
		_smoothed_rtt_usec = roundi(
			RTT_SMOOTHING_FACTOR * rtt_usec
			+ (1.0 - RTT_SMOOTHING_FACTOR)
				* _smoothed_rtt_usec
		)
	else:
		_smoothed_rtt_usec = rtt_usec
		_is_rtt_initialized = true

	# Update adaptive input delay.
	_update_input_delay()

	# Estimate one-way delay as half RTT. Cannot use (t4 - server_t3) because
	# client and server clocks are not synchronized. Mixing clock domains
	# produces incorrect values that cause progressive frame drift.
	var one_way_delay_usec := _smoothed_rtt_usec / 2
	var frames_during_transmission := roundi(
		float(one_way_delay_usec)
		/ (target_network_time_step_sec * 1_000_000.0)
	)

	# Estimate current server frame index.
	var estimated_current_server_frame := (
		server_frame_at_t3 + frames_during_transmission
	)

	var drift := (
		estimated_current_server_frame
		- Netcode.frame_driver.server_frame_index
	)

	# Jitter-aware drift threshold. Convert RTT
	# jitter to frames so noisy estimates do not
	# trigger unnecessary corrections.
	var jitter_frames := ceili(
		rtt_jitter_usec
		/ (target_network_time_step_sec
			* 1_000_000.0)
	)
	var effective_threshold := maxi(
		_MIN_DRIFT_THRESHOLD_FRAMES,
		jitter_frames,
	)

	var fd := Netcode.frame_driver

	# Correct drift if outside threshold.
	if abs(drift) <= effective_threshold:
		# Within acceptable range. Cancel any
		# lingering catch-up if drift has flipped
		# to zero or negative (client at/ahead of
		# server) to prevent overshoot.
		if drift <= 0:
			fd._catchup_frames_remaining = 0
		return

	# Mark frame tracking as initialized so
	# _initialize_frame_tracking() doesn't reset
	# the frame index we're about to set.
	fd._is_frame_tracking_initialized = true

	if drift > 0:
		if drift <= _GRADUAL_CATCHUP_MAX_FRAMES:
			# Small drift: gradually process one
			# extra frame per physics tick to close
			# the gap without visible stutter.
			fd._catchup_frames_remaining = drift
			if Netcode.log.is_verbose:
				Netcode.log.verbose(
					("Client behind by %d frames,"
					+ " gradual catch-up to %d")
					% [
						drift,
						estimated_current_server_frame,
					],
					NetworkLogger
						.CATEGORY_NETWORK_SYNC,
				)
		else:
			# Large drift: instant fast-forward.
			fd.fast_forward(
				estimated_current_server_frame
			)
			if Netcode.log.is_verbose:
				Netcode.log.verbose(
					("Client behind by %d frames,"
					+ " fast-forwarding to %d")
					% [
						drift,
						estimated_current_server_frame,
					],
					NetworkLogger
						.CATEGORY_NETWORK_SYNC,
				)
	else:
		# Client is ahead of server. Cancel any
		# lingering catch-up that caused the
		# overshoot.
		fd._catchup_frames_remaining = 0
		if abs(drift) <= _GRADUAL_CATCHUP_MAX_FRAMES:
			# Small drift: gradually skip physics
			# ticks to let the server catch up.
			# Mirrors the gradual catch-up for
			# client-behind.
			fd._slowdown_frames_remaining = (
				abs(drift)
			)
			if Netcode.log.is_verbose:
				Netcode.log.verbose(
					("Client ahead by %d frames,"
					+ " gradual slow-down")
					% [abs(drift)],
					NetworkLogger
						.CATEGORY_NETWORK_SYNC,
				)
		else:
			# Large drift: hard reset. This can
			# happen when the server runs slower
			# than clients due to performance
			# issues. We need to:
			# 1. Set a grace period so incoming
			#    states aren't rejected.
			# 2. Reinitialize rollback buffers to
			#    clear stale predictions.
			# 3. Reset the frame index.
			var now := Time.get_ticks_usec()
			if (
				now - _last_hard_reset_usec
				< _HARD_RESET_COOLDOWN_USEC
			):
				return
			_last_hard_reset_usec = now
			Netcode.log.warning(
				("Client ahead of server by %d"
				+ " frames! Hard reset from %d"
				+ " to %d") % [
					abs(drift),
					fd.server_frame_index,
					estimated_current_server_frame,
				],
				NetworkLogger
					.CATEGORY_NETWORK_SYNC,
			)
			# Trigger grace period to prevent
			# rejecting valid server states and
			# to suppress fast-forwards from
			# stale buffered packets.
			fd._frame_reset_time_usec = now
			fd._hard_reset_backward_time_usec = (
				now
			)
			# Reinitialize rollback buffers to
			# clear stale predicted data.
			fd.reinitialize_buffers_for_hard_reset(
				estimated_current_server_frame,
			)
			# Reset the frame index.
			fd.server_frame_index = (
				estimated_current_server_frame
			)


func _update_input_delay() -> void:
	if not Netcode.settings.is_adaptive_input_delay_enabled:
		input_delay_frames = 0
		return

	var max_delay: int = Netcode.settings.max_input_delay_frames
	if max_delay <= 0:
		input_delay_frames = 0
		return

	# Target delay = one-way latency in frames.
	var time_step_usec := (
		target_network_time_step_sec * 1_000_000.0
	)
	var target := ceili(
		float(_smoothed_rtt_usec / 2) / time_step_usec
	)
	target = clampi(target, 0, max_delay)

	# Ramp by at most +/-1 per pong to avoid jarring transitions.
	if target > input_delay_frames:
		input_delay_frames = mini(
			input_delay_frames + 1, target
		)
	elif target < input_delay_frames:
		input_delay_frames = maxi(
			input_delay_frames - 1, target
		)
