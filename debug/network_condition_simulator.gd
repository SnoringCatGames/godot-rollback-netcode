class_name NetworkConditionSimulator
extends Node
## Simulates poor network conditions for testing rollback netcode behavior.
##
## This node is created by NetworkOrchestrator in debug builds only. It
## intercepts packed_state updates (via ReconcilableState) in both
## directions and applies configurable latency, jitter, packet loss,
## bandwidth throttling, and latency spikes before delivery.
##
## - **Incoming** (network → local): Delays state arriving from the
##   remote peer before it enters the reconciliation pipeline.
## - **Outgoing** (local → network): Delays the property assignment that
##   triggers MultiplayerSynchronizer replication.
##
## It also supports artificial frame delays to simulate slow-running
## machines (applied in FrameDriver._pre_physics_process).
##
## Configuration is read from Netcode.settings each tick so that values
## changed at runtime (e.g., via the debug UI panel) take effect
## immediately.

## Channel name for predicted state (split-packed nodes).
const CHANNEL_PREDICTED := &"predicted"
## Channel name for authoritative state.
const CHANNEL_AUTHORITATIVE := &"authoritative"

## Presets for common network conditions.
enum Preset {
	NONE,
	GOOD,
	BAD_WIFI,
	MOBILE_3G,
	CHAOS,
}

var _incoming_queue := NetworkDelayQueue.new()
var _outgoing_queue := NetworkDelayQueue.new()

## Spike state.
var _next_spike_msec := 0
var _spike_end_msec := 0

## Per-second stats (exposed for the debug UI).
var stats_queued := 0
var stats_delivered := 0
var stats_dropped := 0
var stats_pending := 0

var is_enabled: bool:
	get:
		if Netcode.settings == null:
			return false
		return Netcode.settings.network_sim_enabled


func _physics_process(_delta: float) -> void:
	if not is_enabled:
		if _incoming_queue.pending_count() > 0:
			_flush_all_immediately(_incoming_queue, true)
		if _outgoing_queue.pending_count() > 0:
			_flush_all_immediately(_outgoing_queue, false)
		return

	_process_incoming_queue()
	_process_outgoing_queue()
	_update_stats()


## Called by ReconcilableState when a new state arrives from the
## network. Instead of processing immediately, we queue it with the
## appropriate delay.
func queue_incoming_state(
	node: ReconcilableState,
	data: Array,
	channel: StringName,
) -> void:
	var delay := _calculate_delay_ms()
	_incoming_queue.enqueue(node, data, channel, delay)


## Called by ReconcilableState when packing local state for outbound
## replication. Instead of assigning to the packed_state property
## immediately, we queue it with the appropriate delay.
func queue_outgoing_state(
	node: ReconcilableState,
	data: Array,
	channel: StringName,
) -> void:
	var delay := _calculate_delay_ms()
	_outgoing_queue.enqueue(node, data, channel, delay)


## Current effective latency including base, jitter, spikes, and
## degradation.
func get_effective_latency_ms() -> int:
	return _calculate_delay_ms()


## Current artificial frame delay in milliseconds.
func get_frame_delay_ms() -> int:
	if Netcode.settings == null:
		return 0
	return Netcode.settings.network_sim_frame_delay_ms


## Apply a preset configuration.
func apply_preset(preset: Preset) -> void:
	if Netcode.settings == null:
		return
	match preset:
		Preset.NONE:
			Netcode.settings.network_sim_enabled = false
			Netcode.settings.network_sim_latency_ms = 0
			Netcode.settings.network_sim_jitter_ms = 0
			Netcode.settings.network_sim_packet_loss_pct = 0.0
			Netcode.settings.network_sim_frame_delay_ms = 0
			Netcode.settings.network_sim_bandwidth_limit = 0
			Netcode.settings.network_sim_spike_interval_sec = 0.0
			Netcode.settings.network_sim_spike_duration_ms = 0
			Netcode.settings.network_sim_spike_latency_ms = 0
		Preset.GOOD:
			Netcode.settings.network_sim_enabled = true
			Netcode.settings.network_sim_latency_ms = 20
			Netcode.settings.network_sim_jitter_ms = 5
			Netcode.settings.network_sim_packet_loss_pct = 0.0
			Netcode.settings.network_sim_frame_delay_ms = 0
			Netcode.settings.network_sim_bandwidth_limit = 0
			Netcode.settings.network_sim_spike_interval_sec = 0.0
			Netcode.settings.network_sim_spike_duration_ms = 0
			Netcode.settings.network_sim_spike_latency_ms = 0
		Preset.BAD_WIFI:
			Netcode.settings.network_sim_enabled = true
			Netcode.settings.network_sim_latency_ms = 80
			Netcode.settings.network_sim_jitter_ms = 40
			Netcode.settings.network_sim_packet_loss_pct = 2.0
			Netcode.settings.network_sim_frame_delay_ms = 0
			Netcode.settings.network_sim_bandwidth_limit = 0
			Netcode.settings.network_sim_spike_interval_sec = 5.0
			Netcode.settings.network_sim_spike_duration_ms = 300
			Netcode.settings.network_sim_spike_latency_ms = 250
		Preset.MOBILE_3G:
			Netcode.settings.network_sim_enabled = true
			Netcode.settings.network_sim_latency_ms = 150
			Netcode.settings.network_sim_jitter_ms = 50
			Netcode.settings.network_sim_packet_loss_pct = 5.0
			Netcode.settings.network_sim_frame_delay_ms = 0
			Netcode.settings.network_sim_bandwidth_limit = 30
			Netcode.settings.network_sim_spike_interval_sec = 0.0
			Netcode.settings.network_sim_spike_duration_ms = 0
			Netcode.settings.network_sim_spike_latency_ms = 0
		Preset.CHAOS:
			Netcode.settings.network_sim_enabled = true
			Netcode.settings.network_sim_latency_ms = 200
			Netcode.settings.network_sim_jitter_ms = 100
			Netcode.settings.network_sim_packet_loss_pct = 10.0
			Netcode.settings.network_sim_frame_delay_ms = 0
			Netcode.settings.network_sim_bandwidth_limit = 0
			Netcode.settings.network_sim_spike_interval_sec = 3.0
			Netcode.settings.network_sim_spike_duration_ms = 500
			Netcode.settings.network_sim_spike_latency_ms = 400


## Clear queues and reset state.
func reset() -> void:
	_incoming_queue.clear()
	_outgoing_queue.clear()
	_next_spike_msec = 0
	_spike_end_msec = 0
	stats_queued = 0
	stats_delivered = 0
	stats_dropped = 0
	stats_pending = 0


# --- Internal ---


func _calculate_delay_ms() -> int:
	if Netcode.settings == null:
		return 0

	var base: int = Netcode.settings.network_sim_latency_ms

	# Jitter: uniform random in [-jitter, +jitter], clamped to >= 0
	# total.
	var jitter: int = Netcode.settings.network_sim_jitter_ms
	if jitter > 0:
		base += randi_range(-jitter, jitter)

	# Spike: periodic high-latency bursts.
	var now := Time.get_ticks_msec()
	if Netcode.settings.network_sim_spike_interval_sec > 0.0:
		if now >= _next_spike_msec:
			_spike_end_msec = (
				now + Netcode.settings.network_sim_spike_duration_ms
			)
			_next_spike_msec = (
				now
				+ int(
					Netcode.settings.network_sim_spike_interval_sec
					* 1000.0
				)
			)
		if now < _spike_end_msec:
			base = maxi(
				base,
				Netcode.settings.network_sim_spike_latency_ms,
			)

	return maxi(base, 0)


func _process_incoming_queue() -> void:
	var loss: float = (
		Netcode.settings.network_sim_packet_loss_pct
		if Netcode.settings else 0.0
	)
	var bw: int = (
		Netcode.settings.network_sim_bandwidth_limit
		if Netcode.settings else 0
	)

	var ready := _incoming_queue.process(loss, bw)
	for entry in ready:
		_deliver_incoming_state(entry)


func _process_outgoing_queue() -> void:
	var loss: float = (
		Netcode.settings.network_sim_packet_loss_pct
		if Netcode.settings else 0.0
	)
	var bw: int = (
		Netcode.settings.network_sim_bandwidth_limit
		if Netcode.settings else 0
	)

	var ready := _outgoing_queue.process(loss, bw)
	for entry in ready:
		_deliver_outgoing_state(entry)


func _deliver_incoming_state(
	entry: NetworkDelayQueue.QueuedState,
) -> void:
	if not is_instance_valid(entry.state_node):
		return
	# Call the normal handler, bypassing the simulator check.
	entry.state_node._handle_new_state_from_network(
		entry.state_data
	)


func _deliver_outgoing_state(
	entry: NetworkDelayQueue.QueuedState,
) -> void:
	if not is_instance_valid(entry.state_node):
		return
	# Assign to the packed_state property to trigger
	# MultiplayerSynchronizer replication. Use the local-packing
	# flag so the setter doesn't re-enter the simulator.
	entry.state_node._is_packing_state_locally = true
	if entry.channel == CHANNEL_PREDICTED:
		if not entry.state_node.predicted_packed_state.is_empty():
			ArrayPool.release(
				entry.state_node.predicted_packed_state
			)
		entry.state_node.predicted_packed_state = (
			entry.state_data
		)
	else:
		if not entry.state_node.authoritative_packed_state.is_empty():
			ArrayPool.release(
				entry.state_node.authoritative_packed_state
			)
		entry.state_node.authoritative_packed_state = (
			entry.state_data
		)
	entry.state_node._is_packing_state_locally = false


func _flush_all_immediately(
	queue: NetworkDelayQueue,
	is_incoming: bool,
) -> void:
	var ready := queue.process(0.0, 0)
	for entry in ready:
		if is_incoming:
			_deliver_incoming_state(entry)
		else:
			_deliver_outgoing_state(entry)
	queue.clear()


func _update_stats() -> void:
	stats_queued = (
		_incoming_queue.states_queued
		+ _outgoing_queue.states_queued
	)
	stats_delivered = (
		_incoming_queue.states_delivered
		+ _outgoing_queue.states_delivered
	)
	stats_dropped = (
		_incoming_queue.states_dropped
		+ _outgoing_queue.states_dropped
	)
	stats_pending = (
		_incoming_queue.pending_count()
		+ _outgoing_queue.pending_count()
	)
