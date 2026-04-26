class_name ArrayPool
extends RefCounted
## Object pool for arrays to reduce allocations in hot paths.
##
## This pool maintains separate pools for different array sizes to avoid
## resizing overhead. Arrays are reused across frames to reduce GC pressure.
##
## Usage:
##   var arr := ArrayPool.acquire(5)
##   # ... use array ...
##   ArrayPool.release(arr)

# Dictionary<int, Array[Array]> - pools indexed by array size
static var _pools_by_size := {}

## Maximum number of arrays to keep in each size pool.
const MAX_POOL_SIZE_PER_BUCKET := 32


## Acquires an array of the specified size from the pool.
## If no pooled array is available, creates a new one.
static func acquire(size: int) -> Array:
	if not _pools_by_size.has(size):
		_pools_by_size[size] = []

	var pool: Array = _pools_by_size[size]
	if pool.is_empty():
		var arr := []
		arr.resize(size)
		return arr

	return pool.pop_back()


## Returns an array to the pool for reuse.
## The array will be cleared before being pooled.
static func release(arr: Array) -> void:
	if arr == null:
		return

	var size := arr.size()
	if not _pools_by_size.has(size):
		_pools_by_size[size] = []

	var pool: Array = _pools_by_size[size]

	# Limit pool size to prevent unbounded memory growth.
	if pool.size() >= MAX_POOL_SIZE_PER_BUCKET:
		return

	# Clear the array before returning to pool.
	for i in range(size):
		arr[i] = null

	pool.append(arr)


## Clears all pooled arrays. Useful for testing or memory management.
static func clear_all_pools() -> void:
	_pools_by_size.clear()


## Returns statistics about the current pool state.
static func get_pool_stats() -> Dictionary:
	var stats := {}
	var total_pooled := 0

	for size in _pools_by_size.keys():
		var pool: Array = _pools_by_size[size]
		stats[size] = pool.size()
		total_pooled += pool.size()

	stats["total_pooled"] = total_pooled
	stats["bucket_count"] = _pools_by_size.size()

	return stats
