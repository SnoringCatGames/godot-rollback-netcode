extends GutTest
## Unit tests for CircularBuffer.

class TestWhenEmpty:
	extends GutTest

	var buffer: CircularBuffer


	func before_each():
		# Clear the array pool to avoid interference between tests.
		ArrayPool.clear_all_pools()
		buffer = CircularBuffer.new(5)


	func after_each():
		ArrayPool.clear_all_pools()


	func test_size_is_zero():
		assert_eq(buffer.size(), 0, "Empty buffer should have size 0")


	func test_is_empty_returns_true():
		assert_true(buffer.is_empty(), "Buffer should be empty")


	func test_is_full_returns_false():
		assert_false(buffer.is_full(), "Empty buffer should not be full")


	func test_get_latest_returns_null():
		assert_null(
			buffer.get_latest(),
			"get_latest should return null when empty",
		)


	func test_get_oldest_returns_null():
		assert_null(
			buffer.get_oldest(),
			"get_oldest should return null when empty",
		)


	func test_get_latest_index_returns_minus_one():
		assert_eq(
			buffer.get_latest_index(),
			-1,
			"get_latest_index should return -1 when empty",
		)


	func test_get_oldest_index_returns_minus_one():
		assert_eq(
			buffer.get_oldest_index(),
			-1,
			"get_oldest_index should return -1 when empty",
		)


	func test_to_array_returns_empty_array():
		var arr := buffer.to_array()
		assert_eq(arr.size(), 0, "to_array should return empty array")


class TestWithSingleElement:
	extends GutTest

	var buffer: CircularBuffer


	func before_each():
		ArrayPool.clear_all_pools()
		buffer = CircularBuffer.new(5)
		buffer.append("first")


	func after_each():
		ArrayPool.clear_all_pools()


	func test_size_is_one():
		assert_eq(buffer.size(), 1)


	func test_is_empty_returns_false():
		assert_false(buffer.is_empty())


	func test_is_full_returns_false():
		assert_false(buffer.is_full())


	func test_get_latest_returns_element():
		assert_eq(buffer.get_latest(), "first")


	func test_get_oldest_returns_element():
		assert_eq(buffer.get_oldest(), "first")


	func test_get_latest_index_returns_zero():
		assert_eq(buffer.get_latest_index(), 0)


	func test_get_oldest_index_returns_zero():
		assert_eq(buffer.get_oldest_index(), 0)


	func test_get_at_zero_returns_element():
		assert_eq(buffer.get_at(0), "first")


	func test_has_at_zero_returns_true():
		assert_true(buffer.has_at(0))


	func test_has_at_negative_returns_false():
		assert_false(buffer.has_at(-1))


	func test_has_at_out_of_range_returns_false():
		assert_false(buffer.has_at(1))


class TestWhenPartiallyFilled:
	extends GutTest

	var buffer: CircularBuffer


	func before_each():
		ArrayPool.clear_all_pools()
		buffer = CircularBuffer.new(5)
		buffer.append("first")
		buffer.append("second")
		buffer.append("third")


	func after_each():
		ArrayPool.clear_all_pools()


	func test_size_matches_element_count():
		assert_eq(buffer.size(), 3)


	func test_is_not_empty():
		assert_false(buffer.is_empty())


	func test_is_not_full():
		assert_false(buffer.is_full())


	func test_get_latest_returns_last_appended():
		assert_eq(buffer.get_latest(), "third")


	func test_get_oldest_returns_first_appended():
		assert_eq(buffer.get_oldest(), "first")


	func test_get_at_retrieves_correct_elements():
		assert_eq(buffer.get_at(0), "first")
		assert_eq(buffer.get_at(1), "second")
		assert_eq(buffer.get_at(2), "third")


	func test_get_latest_index_returns_correct_value():
		assert_eq(buffer.get_latest_index(), 2)


	func test_get_oldest_index_returns_zero():
		assert_eq(buffer.get_oldest_index(), 0)


	func test_to_array_returns_all_elements():
		var arr := buffer.to_array()
		assert_eq(arr.size(), 3)
		assert_eq(arr[0], "first")
		assert_eq(arr[1], "second")
		assert_eq(arr[2], "third")


class TestWhenFull:
	extends GutTest

	var buffer: CircularBuffer


	func before_each():
		ArrayPool.clear_all_pools()
		buffer = CircularBuffer.new(3)
		buffer.append("a")
		buffer.append("b")
		buffer.append("c")


	func after_each():
		ArrayPool.clear_all_pools()


	func test_size_equals_capacity():
		assert_eq(buffer.size(), 3)


	func test_is_full_returns_true():
		assert_true(buffer.is_full())


	func test_is_not_empty():
		assert_false(buffer.is_empty())


	func test_append_overwrites_oldest():
		buffer.append("d")
		assert_eq(buffer.size(), 3, "Size should remain at capacity")
		assert_eq(buffer.get_oldest(), "b", "Oldest should be 'b' now")
		assert_eq(buffer.get_latest(), "d", "Latest should be 'd'")


	func test_get_oldest_index_after_wraparound():
		buffer.append("d")
		assert_eq(buffer.get_oldest_index(), 1)


	func test_has_at_returns_false_for_overwritten_index():
		buffer.append("d")
		# Index 0 ('a') should now be out of range.
		assert_false(buffer.has_at(0))


	func test_get_at_returns_null_for_overwritten_index():
		buffer.append("d")
		assert_null(buffer.get_at(0))


class TestWraparound:
	extends GutTest

	var buffer: CircularBuffer


	func before_each():
		ArrayPool.clear_all_pools()
		buffer = CircularBuffer.new(3)


	func after_each():
		ArrayPool.clear_all_pools()


	func test_multiple_wraparounds_maintain_correct_state():
		# Push 10 elements into a buffer of capacity 3.
		for i in range(10):
			buffer.append(i)

		# The last 3 elements (7, 8, 9) should be in the buffer.
		assert_eq(buffer.size(), 3)
		assert_eq(buffer.get_oldest(), 7)
		assert_eq(buffer.get_at(7), 7)
		assert_eq(buffer.get_at(8), 8)
		assert_eq(buffer.get_at(9), 9)


	func test_oldest_index_after_many_pushes():
		for i in range(10):
			buffer.append(i)
		# Oldest index should be 10 - 3 = 7.
		assert_eq(buffer.get_oldest_index(), 7)


	func test_latest_index_after_many_pushes():
		for i in range(10):
			buffer.append(i)
		assert_eq(buffer.get_latest_index(), 9)


class TestSetAt:
	extends GutTest

	var buffer: CircularBuffer


	func before_each():
		ArrayPool.clear_all_pools()
		buffer = CircularBuffer.new(5)
		buffer.append("a")
		buffer.append("b")
		buffer.append("c")


	func after_each():
		ArrayPool.clear_all_pools()


	func test_set_at_existing_index_updates_value():
		var result := buffer.set_at(1, "modified")
		assert_true(result, "set_at should return true")
		assert_eq(buffer.get_at(1), "modified")


	func test_set_at_invalid_index_returns_false():
		var result := buffer.set_at(10, "invalid")
		assert_false(result, "set_at should return false for invalid index")


	func test_set_at_with_next_index_appends():
		var result := buffer.set_at(3, "d")
		assert_true(result)
		assert_eq(buffer.size(), 4)
		assert_eq(buffer.get_at(3), "d")


	func test_set_at_reuses_array_slot_for_same_size():
		var arr1 := ArrayPool.acquire(3)
		arr1[0] = 1
		arr1[1] = 2
		arr1[2] = 3
		buffer.set_at(1, arr1)

		# Get the pooled array address.
		var pooled_arr: Array = buffer.get_at(1)

		# Create a new array with the same size.
		var arr2 := ArrayPool.acquire(3)
		arr2[0] = 4
		arr2[1] = 5
		arr2[2] = 6

		# set_at should reuse the existing array slot.
		buffer.set_at(1, arr2)

		var reused_arr: Array = buffer.get_at(1)

		# The array instance should be the same (reused).
		assert_same(
			pooled_arr,
			reused_arr,
			"Should reuse existing array slot",
		)
		assert_eq(reused_arr[0], 4)
		assert_eq(reused_arr[1], 5)
		assert_eq(reused_arr[2], 6)


class TestClear:
	extends GutTest

	var buffer: CircularBuffer


	func before_each():
		ArrayPool.clear_all_pools()
		buffer = CircularBuffer.new(5)
		buffer.append("a")
		buffer.append("b")
		buffer.append("c")


	func after_each():
		ArrayPool.clear_all_pools()


	func test_clear_empties_buffer():
		buffer.clear()
		assert_eq(buffer.size(), 0)
		assert_true(buffer.is_empty())
		assert_null(buffer.get_latest())
		assert_null(buffer.get_oldest())


	func test_clear_releases_arrays_to_pool():
		var arr := ArrayPool.acquire(3)
		buffer.append(arr)

		var stats_before := ArrayPool.get_pool_stats()
		buffer.clear()
		var stats_after := ArrayPool.get_pool_stats()

		# The array should have been released back to the pool.
		assert_gt(
			stats_after.get("total_pooled", 0),
			stats_before.get("total_pooled", 0),
			"Array should be released to pool",
		)


class TestForEach:
	extends GutTest

	var buffer: CircularBuffer


	func before_each():
		ArrayPool.clear_all_pools()
		buffer = CircularBuffer.new(5)
		buffer.append(10)
		buffer.append(20)
		buffer.append(30)


	func after_each():
		ArrayPool.clear_all_pools()


	func test_for_each_iterates_all_elements():
		var collected := []
		buffer.for_each(
			func(index: int, value: Variant):
				collected.append([index, value])
		)

		assert_eq(collected.size(), 3)
		assert_eq(collected[0], [0, 10])
		assert_eq(collected[1], [1, 20])
		assert_eq(collected[2], [2, 30])


	func test_for_each_on_empty_buffer_does_not_call_callback():
		buffer.clear()
		var call_count := [0]
		buffer.for_each(
			func(_index: int, _value: Variant):
				call_count[0] += 1
		)
		assert_eq(call_count[0], 0)


class TestArrayPoolIntegration:
	extends GutTest

	var buffer: CircularBuffer


	func before_each():
		ArrayPool.clear_all_pools()
		buffer = CircularBuffer.new(3)


	func after_each():
		ArrayPool.clear_all_pools()


	func test_append_releases_overwritten_arrays():
		var arr1 := ArrayPool.acquire(2)
		var arr2 := ArrayPool.acquire(2)
		var arr3 := ArrayPool.acquire(2)

		buffer.append(arr1)
		buffer.append(arr2)
		buffer.append(arr3)

		var stats_before := ArrayPool.get_pool_stats()

		# This should overwrite arr1 and release it to the pool.
		var arr4 := ArrayPool.acquire(2)
		buffer.append(arr4)

		var stats_after := ArrayPool.get_pool_stats()

		# One array should have been released.
		assert_gt(
			stats_after.get("total_pooled", 0),
			stats_before.get("total_pooled", 0),
			"Overwritten array should be released to pool",
		)
