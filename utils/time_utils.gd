class_name TimeUtils
extends RefCounted
## Simple timer utilities.


var _scene_tree: SceneTree
var _next_id := 1
var _active_callbacks := {} # <int, Callable>
var _start_time_usec := 0
var _is_cleaning_up := false


func _init(scene_tree: SceneTree) -> void:
	_scene_tree = scene_tree
	_start_time_usec = Time.get_ticks_usec()


## Clean up all active callbacks. Call this before freeing.
func cleanup() -> void:
	_is_cleaning_up = true
	_active_callbacks.clear()


func get_time_step_sec() -> float:
	return Netcode.frame_driver.target_network_time_step_sec


## Get play time (same as app time in this simple implementation).
func get_time() -> float:
	return (Time.get_ticks_usec() - _start_time_usec) / 1_000_000.0


## Schedule a callback after a delay.
func set_timeout(callback: Callable, delay_sec: float) -> int:
	if _is_cleaning_up:
		return -1

	var id := _next_id
	_next_id += 1

	var timer := _scene_tree.create_timer(delay_sec)
	var cleanup_callback := func():
		if not _is_cleaning_up and id in _active_callbacks:
			callback.call()
			_active_callbacks.erase(id)

	timer.timeout.connect(cleanup_callback)
	_active_callbacks[id] = cleanup_callback

	return id


## Schedule a callback to repeat at an interval.
func set_interval(callback: Callable, interval_sec: float) -> int:
	if _is_cleaning_up:
		return -1

	var id := _next_id
	_next_id += 1

	# Create wrapper that can be called recursively.
	var wrapper := _IntervalWrapper.new(self , id, callback, interval_sec)
	_active_callbacks[id] = wrapper

	# Start first timer.
	var timer := _scene_tree.create_timer(interval_sec)
	timer.timeout.connect(wrapper.execute)

	return id


## Cancel a timeout or interval.
func clear_timeout(id: int) -> void:
	_active_callbacks.erase(id)


## Create a throttled version of a callback.
## The returned callable accepts variable arguments and passes them through.
func throttle(callback: Callable, cooldown_sec: float) -> Callable:
	# Use array to allow mutation from lambda (arrays are passed by reference).
	var last_call_time := [-INF]

	# Return a callable that accepts any arguments via Variant array.
	return func(args: Array = []) -> void:
		var current_time := Time.get_ticks_msec() / 1000.0
		if current_time - last_call_time[0] >= cooldown_sec:
			last_call_time[0] = current_time
			callback.callv(args)


# --- Helper classes ---


## Wrapper for interval callbacks to avoid self-referencing lambda issues.
class _IntervalWrapper extends RefCounted:
	var _time_utils: TimeUtils
	var _id: int
	var _callback: Callable
	var _interval_sec: float

	func _init(
		time_utils: TimeUtils,
		id: int,
		callback: Callable,
		interval_sec: float
	) -> void:
		_time_utils = time_utils
		_id = id
		_callback = callback
		_interval_sec = interval_sec

	func execute() -> void:
		# Check if TimeUtils is being cleaned up or callback was cancelled.
		if not is_instance_valid(_time_utils) or _time_utils._is_cleaning_up:
			return
		if _id not in _time_utils._active_callbacks:
			return

		# Execute callback.
		_callback.call()

		# Schedule next execution (only if still valid).
		if not _time_utils._is_cleaning_up and is_instance_valid(_time_utils._scene_tree):
			var timer := _time_utils._scene_tree.create_timer(_interval_sec)
			timer.timeout.connect(execute)
