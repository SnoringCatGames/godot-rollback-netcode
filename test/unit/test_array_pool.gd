extends GutTest
## Unit tests for ArrayPool.


func before_each():
	ArrayPool.clear_all_pools()


func after_each():
	ArrayPool.clear_all_pools()


class TestAcquire:
	extends GutTest

	func before_each():
		ArrayPool.clear_all_pools()

	func after_each():
		ArrayPool.clear_all_pools()

	func test_acquire_returns_array_of_correct_size():
		var arr := ArrayPool.acquire(5)
		assert_not_null(arr)
		assert_eq(arr.size(), 5)

	func test_acquire_different_sizes_creates_separate_pools():
		var arr1 := ArrayPool.acquire(3)
		var arr2 := ArrayPool.acquire(5)

		assert_eq(arr1.size(), 3)
		assert_eq(arr2.size(), 5)

		var stats := ArrayPool.get_pool_stats()
		# Acquiring creates buckets even if pools are empty.
		assert_eq(
			stats.get("bucket_count", 0),
			2,
            "Two size buckets should exist after acquiring"
		)
		# But no arrays should be in the pools yet.
		assert_eq(stats.get("total_pooled", 0), 0)

	func test_acquire_creates_new_array_when_pool_empty():
		var arr1 := ArrayPool.acquire(3)
		var arr2 := ArrayPool.acquire(3)

		# Both should be valid but different instances.
		assert_not_null(arr1)
		assert_not_null(arr2)

		# Test that they're different instances by modifying one.
		arr1[0] = 999
		assert_null(
			arr2[0],
            "Modifying arr1 should not affect arr2"
		)


class TestRelease:
	extends GutTest

	func before_each():
		ArrayPool.clear_all_pools()

	func after_each():
		ArrayPool.clear_all_pools()

	func test_release_adds_array_to_pool():
		var arr := ArrayPool.acquire(3)
		arr[0] = 100
		arr[1] = 200
		arr[2] = 300

		ArrayPool.release(arr)

		var stats := ArrayPool.get_pool_stats()
		assert_eq(
			stats.get(3, 0),
			1,
            "Pool for size 3 should have 1 array"
		)
		assert_eq(stats.get("total_pooled", 0), 1)

	func test_release_clears_array_contents():
		var arr := ArrayPool.acquire(3)
		arr[0] = 100
		arr[1] = 200
		arr[2] = 300

		ArrayPool.release(arr)

		# The array should be cleared.
		assert_null(arr[0])
		assert_null(arr[1])
		assert_null(arr[2])

	func test_release_respects_max_pool_size():
		# Acquire more arrays than the max pool size.
		var arrays := []
		for i in range(ArrayPool.MAX_POOL_SIZE_PER_BUCKET + 10):
			arrays.append(ArrayPool.acquire(3))

		# Now release them all.
		for arr in arrays:
			ArrayPool.release(arr)

		var stats := ArrayPool.get_pool_stats()
		# Pool should be capped at MAX_POOL_SIZE_PER_BUCKET.
		assert_eq(
			stats.get(3, 0),
			ArrayPool.MAX_POOL_SIZE_PER_BUCKET,
            "Pool should not exceed max size"
		)


class TestAcquireReleaseCycle:
	extends GutTest

	func before_each():
		ArrayPool.clear_all_pools()

	func after_each():
		ArrayPool.clear_all_pools()

	func test_acquire_reuses_released_arrays():
		var arr1 := ArrayPool.acquire(3)

		ArrayPool.release(arr1)

		var arr2 := ArrayPool.acquire(3)

		var object := Object.new()
		arr1[0] = object

		# Should be the same array instance (reused).
		assert_eq(
			arr2.size(),
			arr1.size(),
			"Should reuse the same array instance",
		)
		assert_eq(arr1[0], arr2[0], "Should reuse the same array instance")

	func test_acquire_after_release_returns_cleared_array():
		var arr1 := ArrayPool.acquire(3)
		arr1[0] = 999
		arr1[1] = 888
		arr1[2] = 777

		ArrayPool.release(arr1)

		var arr2 := ArrayPool.acquire(3)

		# The array should be cleared.
		assert_null(arr2[0])
		assert_null(arr2[1])
		assert_null(arr2[2])


class TestGetPoolStats:
	extends GutTest

	func before_each():
		ArrayPool.clear_all_pools()

	func after_each():
		ArrayPool.clear_all_pools()

	func test_stats_reflect_current_pool_state():
		var arr1 := ArrayPool.acquire(3)
		var arr2 := ArrayPool.acquire(5)
		var arr3 := ArrayPool.acquire(3)

		ArrayPool.release(arr1)
		ArrayPool.release(arr2)
		ArrayPool.release(arr3)

		var stats := ArrayPool.get_pool_stats()

		assert_eq(stats.get(3, 0), 2, "Size 3 pool should have 2 arrays")
		assert_eq(stats.get(5, 0), 1, "Size 5 pool should have 1 array")
		assert_eq(stats.get("total_pooled", 0), 3)
		assert_eq(stats.get("bucket_count", 0), 2)

	func test_stats_for_empty_pool():
		var stats := ArrayPool.get_pool_stats()

		assert_eq(stats.get("total_pooled", 0), 0)
		assert_eq(stats.get("bucket_count", 0), 0)


class TestClearAllPools:
	extends GutTest

	func before_each():
		ArrayPool.clear_all_pools()

	func after_each():
		ArrayPool.clear_all_pools()

	func test_clear_all_pools_removes_all_pooled_arrays():
		for i in range(10):
			var arr := ArrayPool.acquire(3)
			ArrayPool.release(arr)

		var stats_before := ArrayPool.get_pool_stats()
		assert_gt(stats_before.get("total_pooled", 0), 0)

		ArrayPool.clear_all_pools()

		var stats_after := ArrayPool.get_pool_stats()
		assert_eq(stats_after.get("total_pooled", 0), 0)
		assert_eq(stats_after.get("bucket_count", 0), 0)


class TestMultipleSizes:
	extends GutTest

	func before_each():
		ArrayPool.clear_all_pools()

	func after_each():
		ArrayPool.clear_all_pools()

	func test_different_sizes_use_separate_pools():
		var arr3a := ArrayPool.acquire(3)
		var arr3b := ArrayPool.acquire(3)
		var arr5a := ArrayPool.acquire(5)
		var arr5b := ArrayPool.acquire(5)

		ArrayPool.release(arr3a)
		ArrayPool.release(arr3b)
		ArrayPool.release(arr5a)
		ArrayPool.release(arr5b)

		var stats := ArrayPool.get_pool_stats()

		assert_eq(stats.get(3, 0), 2)
		assert_eq(stats.get(5, 0), 2)
		assert_eq(stats.get("bucket_count", 0), 2)
		assert_eq(stats.get("total_pooled", 0), 4)

	func test_acquiring_from_one_pool_does_not_affect_another():
		var arr3 := ArrayPool.acquire(3)
		var arr5 := ArrayPool.acquire(5)

		ArrayPool.release(arr3)
		ArrayPool.release(arr5)

		# Acquire from size 3 pool.
		var _arr3_new := ArrayPool.acquire(3)

		var stats := ArrayPool.get_pool_stats()

		# Size 3 pool should have 0 arrays now.
		assert_eq(stats.get(3, 0), 0)
		# Size 5 pool should still have 1 array.
		assert_eq(stats.get(5, 0), 1)
