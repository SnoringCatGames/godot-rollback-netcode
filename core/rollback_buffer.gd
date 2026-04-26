class_name RollbackBuffer
extends CircularBuffer
## Circular buffer specialized for storing historical network state frames for
## rollback reconciliation.
##
## RollbackBuffer extends CircularBuffer with networking-specific features:
##
## **Key capabilities:**
## - Pre-filled with default frame states on initialization
## - Supports negative indices (-1, -2) for accessing "previous" state before
##   frame 0
## - Allows setting frames at arbitrary (non-sequential) indices within buffer
##   range
## - Automatic back-filling of missing frames with last-known state
## - Memory-efficient array reuse via ArrayPool
##
## **Usage in networking:**
## Each ReconcilableNetworkedState maintains its own RollbackBuffer to store
## historical state snapshots. When a client prediction mismatch is detected,
## the buffer allows "time travel" back to the conflicting frame, followed by
## re-simulation forward to the present.
##
## **Frame storage:**
## - Frames are identified by server_frame_index (integer)
## - Each frame stores an Array of property values plus FrameAuthority
##   (AUTHORITATIVE or PREDICTED)
## - Buffer size is configurable (default ~90 frames @ 60 FPS = 1.5 seconds)
##
## **Special index handling:**
## - Index -1: Default "previous" state for frame 0
## - Index -2: Used when accessing N-2 as "previous" for frame 0
## - These enable consistent frame processing even at simulation start
##
## **Back-filling:**
## When receiving non-sequential networked state (e.g., frame 10 then frame 15),
## backfill_to_with_last_state() fills gaps (frames 11-14) by duplicating frame
## 10's state marked as PREDICTED.
##
## **Memory management:**
## Uses ArrayPool to acquire/release frame state arrays, reducing allocation
## overhead during rollback's high-frequency state manipulation.
##
## Constructed with:
## - capacity: Number of frames to store (circular wrap-around)
## - current_frame_index: Starting frame number
## - default_frame_state: Initial values for all properties

## The default state used to fill new/unset frames.
var _default_frame_state: Array = []


func _init(
		p_capacity: int,
		p_current_frame_index: int,
		p_default_frame_state: Array,
) -> void:
	super._init(p_capacity)

	_default_frame_state = p_default_frame_state

	_reinitialize_data(p_default_frame_state, p_current_frame_index)


## Reinitialize the entire _data array with duplicates of fill_state,
## and set buffer indices to point to target_index + 1.
## Uses array pool to reduce allocations.
func _reinitialize_data(fill_state: Array, target_index: int) -> void:
	for i in range(_capacity):
		# Release old array and acquire new one from pool.
		if _data[i] is Array:
			ArrayPool.release(_data[i])

		var new_arr := ArrayPool.acquire(fill_state.size())
		for j in range(fill_state.size()):
			new_arr[j] = fill_state[j]
		_data[i] = new_arr

	_next_index = (target_index + 1) % _capacity
	_total_pushed = target_index + 1


## Calculate the oldest theoretically accessible index in the buffer.
## - This is limited by the buffer capacity.
## - Returns the oldest valid index, accounting for special negative indices
##   (-1, -2).
func _get_oldest_accessible_index() -> int:
	return maxi(-2, _total_pushed - _capacity)


## Override to allow access to previous frames that haven't been explicitly set,
## as long as they wouldn't wrap around to currently-set frames.
##
## This supports access to -1 and -2:
## - Index -1 is used for the "previous" (default) state for frame 0.
## - Index -2 is used in _pre_network_process when accessing frame N-2 as
##   "previous" state for frame N (where N=0, so N-2=-2).
func has_at(index: int) -> bool:
	if index >= _total_pushed:
		return false

	return index >= _get_oldest_accessible_index()


## Override to allow access to the same indices as has_at, including index -1.
func get_at(index: int) -> Variant:
	if not has_at(index):
		return null
	# Handle index -1 by wrapping to the end of the internal array.
	var internal_index := index % _capacity
	if internal_index < 0:
		internal_index += _capacity
	return _data[internal_index]


## Override set_at to support setting values at arbitrary indices within the
## buffer's range, allowing gaps between the current latest index and the new
## index.
##
## This is needed for rollback buffers where we may receive states for
## non-sequential frames.
func set_at(index: int, value: Variant) -> bool:
	# Don't allow setting values that are too far back in time.
	if index < _get_oldest_accessible_index():
		return false

	var internal_index := index % _capacity

	# Update _total_pushed if we're setting beyond the current latest index.
	if index >= _total_pushed:
		_total_pushed = index + 1
		_next_index = (index + 1) % _capacity

	# Optimization: If both old and new values are arrays of the same size,
	# copy values into the existing array to avoid allocation.
	var existing_value = _data[internal_index]
	if existing_value is Array and value is Array:
		var existing_arr := existing_value as Array
		var new_arr := value as Array
		# Check if they're the same reference - if so, no work needed!
		if existing_arr == new_arr:
			return true
		if existing_arr.size() == new_arr.size():
			for i in range(new_arr.size()):
				existing_arr[i] = new_arr[i]
			# Release the new array back to pool since we reused the existing one.
			ArrayPool.release(new_arr)
			return true

	# Release old array to pool if we're replacing it.
	if existing_value is Array:
		ArrayPool.release(existing_value)

	_data[internal_index] = value
	return true


## Back-fill missing frames using the last recorded state.
func backfill_to_with_last_state(target_index: int) -> void:
	if get_latest_index() >= target_index:
		return

	var latest_state: Array = get_at(get_latest_index())

	# Use array pool for temporary fill_state to avoid allocation.
	var fill_state := ArrayPool.acquire(latest_state.size())
	for i in range(latest_state.size()):
		fill_state[i] = latest_state[i]

	# Backfilled state is not authoritative - use appropriate predicted type.
	var fill_authority := (
		ReconcilableState.FrameAuthority.SERVER_PREDICTED
		if Netcode.is_server
		else ReconcilableState.FrameAuthority
			.CLIENT_PREDICTED
	)
	fill_state[fill_state.size() - 1] = fill_authority

	# If the gap is larger than capacity, just reinitialize the entire array.
	if target_index - get_latest_index() > _capacity:
		_reinitialize_data(fill_state, target_index)
	else:
		_backfill_to(target_index, fill_state)

	# Return temporary array to pool.
	ArrayPool.release(fill_state)


## Back-fill any missing frames in the buffer up to (but not including)
## target_index.
func _backfill_to(target_index: int, fill_state: Variant) -> void:
	while get_latest_index() < target_index:
		var next_index := get_latest_index() + 1
		# Acquire a fresh array for each frame since set_at() may release it.
		var frame_state := ArrayPool.acquire(fill_state.size())
		for i in range(fill_state.size()):
			frame_state[i] = fill_state[i]
		set_at(next_index, frame_state)
