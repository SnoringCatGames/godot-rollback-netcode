class_name NetworkDelayQueue
extends RefCounted
## Queue that delays delivery of network state updates by a configurable
## amount, with support for jitter, packet loss, and bandwidth throttling.
##
## Each queued entry stores the state data, its target entity, and the
## timestamp at which it should be delivered. The queue is processed each
## physics tick by the NetworkConditionSimulator.

## A single queued state update awaiting delivery.
class QueuedState:
	var state_node: ReconcilableState
	var state_data: Array
	var channel: StringName  # CHANNEL_AUTHORITATIVE or CHANNEL_PREDICTED.
	var deliver_at_msec: int

	func _init(
		p_node: ReconcilableState,
		p_data: Array,
		p_channel: StringName,
		p_deliver_at: int,
	) -> void:
		state_node = p_node
		state_data = p_data
		channel = p_channel
		deliver_at_msec = p_deliver_at

var _queue: Array[QueuedState] = []

## Stats (reset each second).
var states_queued := 0
var states_delivered := 0
var states_dropped := 0

## Bandwidth throttle tracking.
var _deliveries_this_second := 0
var _current_second := 0

## Maximum queue size to prevent unbounded memory growth.
const MAX_QUEUE_SIZE := 600


## Add a state to the delay queue with the calculated delivery time.
func enqueue(
	node: ReconcilableState,
	data: Array,
	channel: StringName,
	delay_ms: int,
) -> void:
	# Cap queue size. Drop oldest if full (simulates real network
	# behavior under load).
	if _queue.size() >= MAX_QUEUE_SIZE:
		_queue.pop_front()
		states_dropped += 1

	var deliver_at := Time.get_ticks_msec() + delay_ms
	_queue.append(QueuedState.new(node, data, channel, deliver_at))
	states_queued += 1


## Process the queue: deliver states whose delay has elapsed.
## Returns an array of QueuedState entries ready for delivery.
func process(
	packet_loss_percent: float,
	bandwidth_limit: int,
) -> Array[QueuedState]:
	var now := Time.get_ticks_msec()
	var ready: Array[QueuedState] = []

	# Reset bandwidth counter each second.
	var current_sec := now / 1000
	if current_sec != _current_second:
		_current_second = current_sec
		_deliveries_this_second = 0

	# Walk the queue front-to-back (oldest first).
	var i := 0
	while i < _queue.size():
		var entry := _queue[i]

		if entry.deliver_at_msec > now:
			# Not ready yet; since entries are appended in order, all
			# remaining entries are also not ready.
			break

		# Remove from queue.
		_queue.remove_at(i)
		# Don't increment i; next entry shifts into this slot.

		# Check if the entity is still valid.
		if not is_instance_valid(entry.state_node):
			continue

		# Packet loss roll.
		if packet_loss_percent > 0.0 and randf() * 100.0 < packet_loss_percent:
			states_dropped += 1
			continue

		# Bandwidth throttle.
		if bandwidth_limit > 0 and _deliveries_this_second >= bandwidth_limit:
			states_dropped += 1
			continue

		ready.append(entry)
		states_delivered += 1
		_deliveries_this_second += 1

	return ready


## Clear all pending entries (e.g., on disconnect or reset).
func clear() -> void:
	_queue.clear()
	states_queued = 0
	states_delivered = 0
	states_dropped = 0
	_deliveries_this_second = 0


## Number of entries currently waiting in the queue.
func pending_count() -> int:
	return _queue.size()
