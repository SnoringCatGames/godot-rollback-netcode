class_name CircularBuffer
extends RefCounted
## A fixed-size circular buffer (ring buffer) data structure.
##
## Elements are stored in a fixed-size array and wrap around when the buffer
## is full. This is useful for rollback buffers, history tracking, and any
## scenario where you need to maintain a sliding window of recent values.
##
## Usage:
##   var buffer = CircularBuffer.new(10)
##   buffer.append(value1)
##   buffer.append(value2)
##   var latest = buffer.get_latest()
##   var oldest = buffer.get_oldest()
##   var at_index = buffer.get_at(index)

## The internal array storing buffer elements.
var _data: Array = []

## The maximum number of elements the buffer can hold.
var _capacity: int = 0

## The index in _data where the next element will be written.
var _next_index: int = 0

## The total number of elements that have been pushed (used for indexing).
var _total_pushed: int = 0

## The maximum number of elements the buffer can hold.
var capacity: int:
	get:
		return _capacity


func _init(p_capacity: int) -> void:
	Netcode.log.check(p_capacity > 0, "CircularBuffer capacity must be greater than 0")
	_capacity = p_capacity
	_data.resize(p_capacity)
	for i in range(p_capacity):
		_data[i] = null


## The current number of valid elements in the buffer.
func size() -> int:
	if is_full():
		return _capacity
	return _next_index


## True if the buffer contains no elements.
func is_empty() -> bool:
	return _total_pushed == 0


## True if the buffer has reached its capacity.
func is_full() -> bool:
	return _total_pushed >= _capacity


## - Adds a new element to the buffer. If the buffer is full, the oldest element
##   is overwritten.
## - Returns the index of the pushed element.
## - Releases old array to pool when overwriting.
func append(value: Variant) -> int:
	var index := _total_pushed

	# If overwriting and the old value is an array, release it to the pool.
	if is_full() and _data[_next_index] is Array:
		ArrayPool.release(_data[_next_index])

	_data[_next_index] = value
	_next_index = (_next_index + 1) % _capacity
	_total_pushed += 1
	return index


## - Gets the most recently pushed element.
## - Returns null if the buffer is empty.
func get_latest() -> Variant:
	if is_empty():
		return null
	var index := (_next_index - 1 + _capacity) % _capacity
	return _data[index]


## - Gets the oldest element still in the buffer.
## - Returns null if the buffer is empty.
func get_oldest() -> Variant:
	if is_empty():
		return null
	if is_full():
		return _data[_next_index]
	return _data[0]


## - Gets an element by its absolute index (the index returned by append()).
## - Returns null if the index is out of the valid range.
func get_at(index: int) -> Variant:
	if not has_at(index):
		return null
	var internal_index := index % _capacity
	return _data[internal_index]


## - Sets an element at a specific index.
## - Returns true if successful, false if the index is out of valid range.
## - For arrays, reuses existing array slot if same size to reduce allocations.
func set_at(index: int, value: Variant) -> bool:
	if index == _total_pushed:
		# Push a new item.
		append(value)
		return true

	if not has_at(index):
		return false
	var internal_index := index % _capacity

	# Optimization: If both old and new values are arrays of the same size,
	# copy values into the existing array to avoid allocation.
	var existing_value = _data[internal_index]
	if existing_value is Array and value is Array:
		var existing_arr := existing_value as Array
		var new_arr := value as Array
		if existing_arr.size() == new_arr.size():
			for i in range(new_arr.size()):
				existing_arr[i] = new_arr[i]
			# Release the new array back to pool since we reused the existing
			# one.
			ArrayPool.release(new_arr)
			return true

	# Release old array to pool if we're replacing it.
	if existing_value is Array:
		ArrayPool.release(existing_value)

	_data[internal_index] = value
	return true


## Checks if an index is within the valid range of the buffer.
func has_at(index: int) -> bool:
	if index < 0:
		return false
	if index >= _total_pushed:
		return false
	var oldest_valid_index := get_oldest_index()
	return index >= oldest_valid_index


## - Returns the index of the most recently pushed element.
## - Returns -1 if the buffer is empty.
func get_latest_index() -> int:
	if is_empty():
		return -1
	return _total_pushed - 1


## - Returns the index of the oldest element still in the buffer.
## - Returns -1 if the buffer is empty.
func get_oldest_index() -> int:
	if is_empty():
		return -1
	if is_full():
		return _total_pushed - _capacity
	return 0


## Clears all elements from the buffer.
## Releases arrays back to pool.
func clear() -> void:
	for i in range(_capacity):
		# Release arrays back to pool before clearing.
		if _data[i] is Array:
			ArrayPool.release(_data[i])
		_data[i] = null
	_next_index = 0
	_total_pushed = 0


## Returns an array of all valid elements, from oldest to newest.
func to_array() -> Array:
	var oldest_index := get_oldest_index()
	var result: Array = []
	for i in range(size()):
		result.append(get_at(oldest_index + i))
	return result


## - Iterates over all valid elements from oldest to newest.
## - Calls the callback with (index, value) for each element.
func for_each(callback: Callable) -> void:
	var oldest_index := get_oldest_index()
	var latest_index := get_latest_index()
	if oldest_index < 0:
		return
	for index in range(oldest_index, latest_index + 1):
		callback.call(index, get_at(index))
