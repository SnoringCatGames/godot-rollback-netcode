extends GutTest
## Unit tests for RollbackBuffer.


func before_each():
	ArrayPool.clear_all_pools()


func after_each():
	ArrayPool.clear_all_pools()


class TestInitialization:
	extends GutTest

	func before_each():
		ArrayPool.clear_all_pools()


	func after_each():
		ArrayPool.clear_all_pools()


	func test_buffer_initializes_with_default_state():
		var default_state := [100, 200, 0]
		var buffer := RollbackBuffer.new(5, 0, default_state)

		# Check that frame 0 has default state.
		# (Frames -2 and -1 are also accessible but harder to verify.)
		var state: Array = buffer.get_at(0)
		assert_not_null(state, "Frame 0 should exist")
		assert_eq(state[0], 100)
		assert_eq(state[1], 200)

		# Verify buffer reports correct latest index.
		assert_eq(buffer.get_latest_index(), 0)


	func test_buffer_starts_at_target_index():
		var default_state := [0, 0, 0]
		var buffer := RollbackBuffer.new(5, 10, default_state)

		# Latest index should be target_index.
		assert_eq(buffer.get_latest_index(), 10)


	func test_buffer_uses_array_pool_for_initialization():
		var default_state := [1, 2, 3]
		var buffer := RollbackBuffer.new(3, 0, default_state)

		# Check that state arrays have correct size.
		# Access frames that should exist.
		for frame_index in [-2, -1, 0]:
			var state: Array = buffer.get_at(frame_index)
			assert_true(state is Array)
			assert_eq(state.size(), 3)


class TestNegativeIndices:
	extends GutTest

	func before_each():
		ArrayPool.clear_all_pools()


	func after_each():
		ArrayPool.clear_all_pools()


	func test_has_at_allows_negative_one():
		var default_state := [0, 0, 0]
		var buffer := RollbackBuffer.new(5, 0, default_state)

		assert_true(
			buffer.has_at(-1),
			"Index -1 should be accessible",
		)


	func test_has_at_allows_negative_two():
		var default_state := [0, 0, 0]
		var buffer := RollbackBuffer.new(5, 0, default_state)

		assert_true(
			buffer.has_at(-2),
			"Index -2 should be accessible",
		)


	func test_has_at_rejects_negative_three():
		var default_state := [0, 0, 0]
		var buffer := RollbackBuffer.new(5, 0, default_state)

		assert_false(
			buffer.has_at(-3),
			"Index -3 should not be accessible",
		)


	func test_get_at_negative_one_returns_valid_state():
		var default_state := [100, 200, 0]
		var buffer := RollbackBuffer.new(5, 0, default_state)

		var state: Array = buffer.get_at(-1)
		assert_not_null(state)
		assert_eq(state[0], 100)
		assert_eq(state[1], 200)


	func test_get_at_negative_two_returns_valid_state():
		var default_state := [50, 75, 0]
		var buffer := RollbackBuffer.new(5, 0, default_state)

		var state: Array = buffer.get_at(-2)
		assert_not_null(state)
		assert_eq(state[0], 50)
		assert_eq(state[1], 75)


class TestBackfill:
	extends GutTest

	func before_each():
		ArrayPool.clear_all_pools()


	func after_each():
		ArrayPool.clear_all_pools()


	func test_backfill_to_with_last_state_fills_missing_frames():
		var default_state := [0, 0, 0]
		var buffer := RollbackBuffer.new(10, 0, default_state)

		# Advance buffer to frame 4 by appending dummy states.
		for i in range(4):
			var state := ArrayPool.acquire(3)
			state[0] = 0
			state[1] = 0
			state[2] = ReconcilableState.FrameAuthority.CLIENT_PREDICTED
			buffer.append(state)

		# Append state at frame 5 with specific values.
		var state_5 := ArrayPool.acquire(3)
		state_5[0] = 100
		state_5[1] = 200
		state_5[2] = ReconcilableState.FrameAuthority.AUTHORITATIVE
		buffer.append(state_5)

		# Backfill to frame 8.
		buffer.backfill_to_with_last_state(8)

		# Frames 6 and 7 should now exist with state from frame 5.
		var state_6: Array = buffer.get_at(6)
		var state_7: Array = buffer.get_at(7)

		assert_not_null(state_6)
		assert_not_null(state_7)

		assert_eq(state_6[0], 100)
		assert_eq(state_6[1], 200)
		# Backfilled states should be SERVER_PREDICTED (tests run as server).
		assert_eq(state_6[2], ReconcilableState.FrameAuthority.SERVER_PREDICTED)

		assert_eq(state_7[0], 100)
		assert_eq(state_7[1], 200)
		assert_eq(state_7[2], ReconcilableState.FrameAuthority.SERVER_PREDICTED)


	func test_backfill_does_nothing_if_already_filled():
		var default_state := [0, 0, 0]
		var buffer := RollbackBuffer.new(10, 5, default_state)

		var latest_before := buffer.get_latest_index()

		# Try to backfill to a frame that's already filled.
		buffer.backfill_to_with_last_state(3)

		# Latest index should not change.
		assert_eq(buffer.get_latest_index(), latest_before)


	func test_backfill_large_gap_reinitializes_buffer():
		var default_state := [10, 20, 0]
		var buffer := RollbackBuffer.new(5, 0, default_state)

		# Set state at frame 0.
		var state_0 := ArrayPool.acquire(3)
		state_0[0] = 999
		state_0[1] = 888
		state_0[2] = ReconcilableState.FrameAuthority.AUTHORITATIVE
		buffer.set_at(0, state_0)

		# Backfill to frame 100 (way beyond capacity).
		buffer.backfill_to_with_last_state(100)

		# Latest index should now be 100.
		assert_eq(buffer.get_latest_index(), 100)

		# State at frame 100 should be based on frame 0 (but SERVER_PREDICTED since
		# tests run as server).
		var state_100: Array = buffer.get_at(100)
		assert_eq(state_100[0], 999)
		assert_eq(state_100[1], 888)
		assert_eq(state_100[2], ReconcilableState.FrameAuthority.SERVER_PREDICTED)


class TestSetAndGet:
	extends GutTest

	func before_each():
		ArrayPool.clear_all_pools()


	func after_each():
		ArrayPool.clear_all_pools()


	func test_set_and_get_at_frame():
		var default_state := [0, 0, 0]
		var buffer := RollbackBuffer.new(10, 0, default_state)

		var state := ArrayPool.acquire(3)
		state[0] = 42
		state[1] = 84
		state[2] = ReconcilableState.FrameAuthority.AUTHORITATIVE

		buffer.set_at(5, state)

		var retrieved: Array = buffer.get_at(5)
		assert_eq(retrieved[0], 42)
		assert_eq(retrieved[1], 84)
		assert_eq(retrieved[2], ReconcilableState.FrameAuthority.AUTHORITATIVE)


	func test_get_at_out_of_range_returns_null():
		var default_state := [0, 0, 0]
		var buffer := RollbackBuffer.new(5, 10, default_state)

		# Frame 0 is way out of range (oldest accessible is 10 - 5 = 5).
		assert_null(buffer.get_at(0))


	func test_has_at_respects_buffer_capacity():
		var default_state := [0, 0, 0]
		var buffer := RollbackBuffer.new(5, 20, default_state)

		# Buffer initialized at frame 20, so _total_pushed = 21.
		# Oldest accessible = _total_pushed - capacity = 21 - 5 = 16.
		assert_true(buffer.has_at(16))
		assert_true(buffer.has_at(20))
		assert_false(buffer.has_at(15))
		assert_false(buffer.has_at(21))


	func test_set_at_with_gap_updates_latest_index():
		var default_state := [0, 0, 0]
		var buffer := RollbackBuffer.new(10, 0, default_state)

		# Set state at frame 5 (skipping frames 1-4).
		var state := ArrayPool.acquire(3)
		state[0] = 42
		state[1] = 84
		state[2] = ReconcilableState.FrameAuthority.AUTHORITATIVE

		var success := buffer.set_at(5, state)

		assert_true(success, "set_at should succeed")
		assert_eq(buffer.get_latest_index(), 5, "Latest index should be 5")

		var retrieved: Array = buffer.get_at(5)
		assert_eq(retrieved[0], 42)
		assert_eq(retrieved[1], 84)
		assert_eq(retrieved[2], ReconcilableState.FrameAuthority.AUTHORITATIVE)


	func test_set_at_rejects_index_too_far_back():
		var default_state := [0, 0, 0]
		var buffer := RollbackBuffer.new(5, 20, default_state)

		# Try to set at frame 10 (oldest accessible is 20 - 5 = 15).
		var state := ArrayPool.acquire(3)
		state[0] = 100
		state[1] = 200
		state[2] = ReconcilableState.FrameAuthority.AUTHORITATIVE

		var success := buffer.set_at(10, state)

		assert_false(success, "set_at should fail for index too far back")
		ArrayPool.release(state)


class TestAppend:
	extends GutTest

	func before_each():
		ArrayPool.clear_all_pools()


	func after_each():
		ArrayPool.clear_all_pools()


	func test_append_adds_new_frame():
		var default_state := [0, 0, 0]
		var buffer := RollbackBuffer.new(10, 0, default_state)

		var latest_before := buffer.get_latest_index()

		var state := ArrayPool.acquire(3)
		state[0] = 123
		state[1] = 456
		state[2] = ReconcilableState.FrameAuthority.AUTHORITATIVE

		buffer.append(state)

		assert_eq(buffer.get_latest_index(), latest_before + 1)

		var retrieved: Array = buffer.get_latest()
		assert_eq(retrieved[0], 123)
		assert_eq(retrieved[1], 456)


	func test_append_overwrites_oldest_when_full():
		var default_state := [0, 0, 0]
		var buffer := RollbackBuffer.new(3, 0, default_state)

		# Fill the buffer beyond capacity.
		# Buffer starts at frame 0, then we append to frames 1, 2, 3, 4, 5.
		for i in range(5):
			var state := ArrayPool.acquire(3)
			state[0] = i * 10
			state[1] = i * 20
			state[2] = ReconcilableState.FrameAuthority.AUTHORITATIVE
			buffer.append(state)

		# After 5 appends starting from frame 0, we're at frame 5.
		# With capacity 3, oldest should be frame 3.
		assert_eq(buffer.get_oldest_index(), 3)

		# Frame 3 was created by the 3rd append (i=2).
		var oldest: Array = buffer.get_oldest()
		assert_eq(oldest[0], 20) # i=2: 2 * 10 = 20
		assert_eq(oldest[1], 40) # i=2: 2 * 20 = 40


class TestClear:
	extends GutTest

	func before_each():
		ArrayPool.clear_all_pools()


	func after_each():
		ArrayPool.clear_all_pools()


	func test_clear_resets_buffer():
		var default_state := [0, 0, 0]
		var buffer := RollbackBuffer.new(5, 10, default_state)

		var state := ArrayPool.acquire(3)
		state[0] = 999
		buffer.append(state)

		buffer.clear()

		assert_eq(buffer.size(), 0)
		assert_true(buffer.is_empty())
		assert_null(buffer.get_latest())


	func test_clear_releases_arrays_to_pool():
		var default_state := [0, 0, 0]
		var buffer := RollbackBuffer.new(3, 0, default_state)

		# The buffer should have arrays from initialization.
		var stats_before := ArrayPool.get_pool_stats()

		buffer.clear()

		var stats_after := ArrayPool.get_pool_stats()

		# Arrays should be released.
		assert_gt(
			stats_after.get("total_pooled", 0),
			stats_before.get("total_pooled", 0),
			"Clear should release arrays to pool",
		)
