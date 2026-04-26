class_name InputDelayBuffer
extends RefCounted
## Rollback-safe input delay buffer using a circular buffer with frame-indexed
## slots for implementing adaptive input delay.
##
## Uses modulo indexing (frame_index % capacity) to map frames to slots,
## ensuring that re-simulating the same frame during rollback always writes to
## the same slot (deterministic, idempotent).
##
## Tracks the valid frame range [_oldest_frame_index, _newest_frame_index] to
## handle pruning efficiently without iterating all slots.

## Buffer capacity. Should exceed max_input_delay + rollback_buffer_duration.
## At 60 FPS: 8 delay + 120 rollback (2 sec) = 128, round up to 256.
const _CAPACITY := 256

## Circular buffer storing input bitmasks.
var _buffer: Array[int] = []

## Oldest frame index currently stored in buffer (-1 if empty).
var _oldest_frame_index := -1

## Newest frame index currently stored in buffer (-1 if empty).
var _newest_frame_index := -1


func _init() -> void:
	_buffer.resize(_CAPACITY)
	_buffer.fill(0)


## Stores raw input bitmask for the given frame. If this frame was already
## stored (e.g., during rollback re-simulation), the new value overwrites the
## old one at the same slot, ensuring deterministic re-simulation.
func store(frame_index: int, bitmask: int) -> void:
	var slot := frame_index % _CAPACITY
	_buffer[slot] = bitmask

	# Update frame range tracking.
	if _oldest_frame_index < 0:
		# First frame stored.
		_oldest_frame_index = frame_index
		_newest_frame_index = frame_index
	else:
		if frame_index > _newest_frame_index:
			_newest_frame_index = frame_index

		# Prune old frames that would be overwritten by wrapping.
		# If the new frame's slot would contain a frame that's more than
		# _CAPACITY frames old, we've wrapped around and need to advance
		# oldest.
		var frames_in_buffer := _newest_frame_index - _oldest_frame_index + 1
		if frames_in_buffer > _CAPACITY:
			# We've exceeded capacity - advance oldest to maintain size.
			_oldest_frame_index = _newest_frame_index - _CAPACITY + 1


## Returns the raw bitmask stored at the given frame. Returns 0 if the frame
## is not in the valid range [oldest, newest].
func get_raw(frame_index: int) -> int:
	# Check if frame is in valid range.
	if _oldest_frame_index < 0:
		return 0  # Buffer empty.
	if frame_index < _oldest_frame_index or frame_index > _newest_frame_index:
		return 0  # Outside valid range.

	var slot := frame_index % _CAPACITY
	return _buffer[slot]


## Returns the bitmask from (frame_index - delay). Returns 0 if the delayed
## frame is not in the valid range [oldest, newest].
func get_delayed(frame_index: int, delay: int) -> int:
	if delay == 0:
		return 0

	var target_frame := frame_index - delay
	return get_raw(target_frame)


## Resets the buffer, clearing all stored input. Called when the delay buffer
## owner is removed from the scene.
func reset() -> void:
	_buffer.fill(0)
	_oldest_frame_index = -1
	_newest_frame_index = -1
