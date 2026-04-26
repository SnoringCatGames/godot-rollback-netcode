@tool
extends GutTest
## Unit tests for FrameDriver.

func before_each():
	ArrayPool.clear_all_pools()


func after_each():
	ArrayPool.clear_all_pools()


class TestRollbackQueueing:
	extends GutTest
	## Tests rollback scheduling, deduplication, and validation.

	var frame_driver: FrameDriver


	func before_each():
		ArrayPool.clear_all_pools()
		frame_driver = FrameDriver.new()


	func after_each():
		ArrayPool.clear_all_pools()
		if is_instance_valid(frame_driver):
			frame_driver.free()


	func test_queue_rollback_accepts_valid_frame():
		# Frame index at 50, buffer size 120.
		frame_driver.server_frame_index = 50

		# Queue rollback to frame 45 (conflict frame).
		# This becomes target rollback frame 46 (conflict + 1).
		var result := frame_driver.queue_rollback(45)

		assert_true(result, "Should accept valid rollback request")


	func test_queue_rollback_rejects_too_old_frame():
		# Set up: frame index at 200, buffer size 120.
		# oldest_rollbackable = max(200 - 120 + 3, 1) = 83.
		frame_driver.server_frame_index = 200

		# Try to queue rollback to frame 80 (too old).
		# Target rollback would be 81, which is < 83.
		var result := frame_driver.queue_rollback(80)

		assert_false(
			result,
			"Should reject rollback request for frame too old",
		)


	func test_queue_rollback_boundary_frame_accepted():
		# Test the boundary case: exactly at oldest_rollbackable.
		frame_driver.server_frame_index = 200
		# oldest_rollbackable = max(200 - 120 + 3, 1) = 83.

		# Queue rollback to frame 82 (conflict).
		# Target rollback = 83, which equals oldest_rollbackable.
		var result := frame_driver.queue_rollback(82)

		assert_true(
			result,
			"Should accept rollback at boundary (oldest_rollbackable)",
		)


	func test_queue_rollback_boundary_frame_rejected():
		# Test one frame before the boundary.
		frame_driver.server_frame_index = 200
		# oldest_rollbackable = 83.

		# Queue rollback to frame 81 (conflict).
		# Target rollback = 82, which is < 83.
		var result := frame_driver.queue_rollback(81)

		assert_false(
			result,
			"Should reject rollback one frame before oldest_rollbackable",
		)


	func test_queue_rollback_deduplication_keeps_earliest():
		# Multiple queue_rollback calls should keep the earliest
		# target frame.
		frame_driver.server_frame_index = 50

		frame_driver.queue_rollback(47) # Target: 48.
		frame_driver.queue_rollback(45) # Target: 46 (earlier).
		frame_driver.queue_rollback(49) # Target: 50 (later).

		assert_eq(
			frame_driver._queued_rollback_frame_index,
			46,
			"Should keep earliest rollback target (46)",
		)


	func test_queue_rollback_clears_after_processing():
		# After _run_network_process, the queued rollback should
		# be cleared.
		frame_driver.server_frame_index = 50
		frame_driver.queue_rollback(45)

		assert_eq(
			frame_driver._queued_rollback_frame_index,
			46,
			"Rollback should be queued at frame 46",
		)

		frame_driver._run_network_process()

		assert_eq(
			frame_driver._queued_rollback_frame_index,
			0,
			"Rollback queue should be cleared after processing",
		)


	func test_frame_index_restored_after_rollback_processing():
		# After rollback + resimulation, frame index should be
		# restored to its original value.
		frame_driver.server_frame_index = 50
		frame_driver.queue_rollback(45)

		frame_driver._run_network_process()

		assert_eq(
			frame_driver.server_frame_index,
			50,
			"Frame index should be restored after rollback",
		)


	func test_rollback_to_current_frame_accepted():
		# Edge case: rollback to current frame should be accepted
		# but results in zero re-simulation frames.
		frame_driver.server_frame_index = 50

		var result := frame_driver.queue_rollback(49)

		assert_true(
			result,
			"Should accept rollback to current frame",
		)


	func test_is_frame_too_old_at_boundary():
		# Test the boundary check for is_frame_too_old_to_consider.
		frame_driver.server_frame_index = 200
		# oldest_rollbackable = 83.

		# Frame 82 (conflict), target 83 - should NOT be too old.
		var result_at_boundary := frame_driver.is_frame_too_old_to_consider(82)
		assert_false(
			result_at_boundary,
			"Frame at boundary should not be too old",
		)

		# Frame 81 (conflict), target 82 - should be too old.
		var result_before_boundary := (
			frame_driver.is_frame_too_old_to_consider(81)
		)
		assert_true(
			result_before_boundary,
			"Frame before boundary should be too old",
		)


	func test_oldest_rollbackable_never_negative():
		# Test early frames where buffer size exceeds frame index.
		frame_driver.server_frame_index = 5
		# Formula: max(5 - 120 + 3, 1) = max(-112, 1) = 1.

		var oldest := frame_driver.oldest_rollbackable_frame_index

		assert_eq(
			oldest,
			1,
			"Oldest rollbackable should never be less than 1",
		)


	func test_rollback_buffer_size_calculation():
		# Test that buffer size is calculated correctly.
		# Default: 2.0 seconds at 60 FPS = 120 frames.
		var expected_size := ceili(
			Netcode.settings.rollback_buffer_duration_sec
			* frame_driver.target_network_fps,
		)

		var actual_size := frame_driver.rollback_buffer_size

		assert_eq(
			actual_size,
			expected_size,
			"Buffer size should match settings",
		)


## Test helper entity that tracks network processing calls.
class TestFrameProcessor \
	extends FrameProcessor:
	## Tracks how many times each processing phase is called.

	var pre_process_count := 0
	var network_process_count := 0
	var post_process_count := 0
	var processed_frames: Array[int] = []


	func _pre_network_process() -> void:
		pre_process_count += 1


	func _network_process() -> void:
		network_process_count += 1
		processed_frames.append(Netcode.server_frame_index)


	func _post_network_process() -> void:
		post_process_count += 1


	func reset() -> void:
		pre_process_count = 0
		network_process_count = 0
		post_process_count = 0
		processed_frames.clear()




class TestFastForward:
	extends GutTest
	## Tests frame skip handling when client falls behind server.

	var frame_driver: FrameDriver


	func before_each():
		ArrayPool.clear_all_pools()
		frame_driver = FrameDriver.new()


	func after_each():
		ArrayPool.clear_all_pools()
		if is_instance_valid(frame_driver):
			frame_driver.free()


	func test_fast_forward_advances_frame_index():
		# Start at frame 10, fast forward to frame 20.
		frame_driver.server_frame_index = 10

		frame_driver.fast_forward(20)

		assert_eq(
			frame_driver.server_frame_index,
			20,
			"Should advance to frame 20",
		)


	func test_fast_forward_processes_intermediate_frames():
		# Fast forward from 10 to 15 should process frames 11-15.
		frame_driver.server_frame_index = 10

		var processor := TestFrameProcessor.new()
		frame_driver.add_frame_processor(processor)

		frame_driver.fast_forward(15)

		assert_eq(
			processor.network_process_count,
			5,
			"Should process 5 intermediate frames",
		)
		assert_eq(
			frame_driver.server_frame_index,
			15,
			"Should advance to target frame",
		)

		frame_driver.remove_frame_processor(processor)
		processor.free()


	func test_fast_forward_with_zero_gap():
		# Fast forward to current frame should be no-op.
		frame_driver.server_frame_index = 50

		frame_driver.fast_forward(50)

		assert_eq(
			frame_driver.server_frame_index,
			50,
			"Should remain at frame 50",
		)


	func test_fast_forward_with_one_frame_gap():
		# Edge case: fast forward by exactly 1 frame.
		frame_driver.server_frame_index = 30

		frame_driver.fast_forward(31)

		assert_eq(
			frame_driver.server_frame_index,
			31,
			"Should advance by exactly 1 frame",
		)


	func test_fast_forward_large_gap():
		# Test with a large gap (100 frames).
		frame_driver.server_frame_index = 10

		frame_driver.fast_forward(110)

		assert_eq(
			frame_driver.server_frame_index,
			110,
			"Should handle large frame gaps",
		)


class TestNodeRegistration:
	extends GutTest
	## Tests ReconcilableNetworkedState and FrameProcessor lifecycle.

	var frame_driver: FrameDriver
	var test_entity: TestNetworkedEntity


	func before_each():
		ArrayPool.clear_all_pools()
		frame_driver = Netcode.frame_driver


	func after_each():
		ArrayPool.clear_all_pools()
		if is_instance_valid(test_entity):
			test_entity.queue_free()


	func test_add_networked_state_registers_node():
		# Create a test networked entity.
		test_entity = TestNetworkedEntity.new()

		# Manually add to frame driver.
		var initial_count := frame_driver._networked_state_nodes.size()
		frame_driver.add_networked_state(test_entity)

		assert_eq(
			frame_driver._networked_state_nodes.size(),
			initial_count + 1,
			"Should add entity to _networked_state_nodes",
		)
		assert_true(
			frame_driver._networked_state_nodes.has(test_entity),
			"Should contain the test entity",
		)


	func test_remove_networked_state_unregisters_node():
		# Create and register test entity.
		test_entity = TestNetworkedEntity.new()
		frame_driver.add_networked_state(test_entity)

		# Remove entity.
		var count_before := frame_driver._networked_state_nodes.size()
		frame_driver.remove_networked_state(test_entity)

		assert_eq(
			frame_driver._networked_state_nodes.size(),
			count_before - 1,
			"Should remove entity from _networked_state_nodes",
		)
		assert_false(
			frame_driver._networked_state_nodes.has(test_entity),
			"Should not contain the test entity",
		)


	func test_add_frame_processor_registers_node():
		# Create a test node with FrameProcessor interface.
		var processor := TestFrameProcessor.new()

		# Manually add to frame driver.
		var initial_count: int = frame_driver._frame_processor_nodes.size()
		frame_driver.add_frame_processor(processor)

		assert_eq(
			frame_driver._frame_processor_nodes.size(),
			initial_count + 1,
			"Should add processor to _frame_processor_nodes",
		)
		assert_true(
			frame_driver._frame_processor_nodes.has(processor),
			"Should contain the test processor",
		)

		# Cleanup.
		frame_driver.remove_frame_processor(processor)
		processor.free()


	func test_remove_frame_processor_unregisters_node():
		# Create and register test processor.
		var processor := TestFrameProcessor.new()
		frame_driver.add_frame_processor(processor)

		# Remove processor.
		var count_before: int = frame_driver._frame_processor_nodes.size()
		frame_driver.remove_frame_processor(processor)

		assert_eq(
			frame_driver._frame_processor_nodes.size(),
			count_before - 1,
			"Should remove processor from _frame_processor_nodes",
		)
		assert_false(
			frame_driver._frame_processor_nodes.has(processor),
			"Should not contain the test processor",
		)

		# Cleanup.
		processor.free()


class TestPauseUnpause:
	extends GutTest
	## Tests pause/unpause functionality including state tracking, frame
	## continuity, and time adjustments.

	var frame_driver: FrameDriver


	func before_each():
		ArrayPool.clear_all_pools()
		frame_driver = FrameDriver.new()
		add_child_autofree(frame_driver)


	func after_each():
		ArrayPool.clear_all_pools()


	func test_starts_paused_by_default():
		# Game should start paused until server unpauses.
		assert_true(
			frame_driver.is_paused,
			"Should start paused by default",
		)


	func test_server_set_is_paused_true_pauses_simulation():
		# Unpause first.
		frame_driver._is_paused = false

		# Then pause via server_set_is_paused.
		frame_driver.server_set_is_paused(true)

		assert_true(
			frame_driver.is_paused,
			"Should be paused after server_set_is_paused(true)",
		)


	func test_server_set_is_paused_false_unpauses_simulation():
		# Start paused.
		frame_driver._is_paused = true

		# Unpause via server_set_is_paused.
		frame_driver.server_set_is_paused(false)

		assert_false(
			frame_driver.is_paused,
			"Should be unpaused after server_set_is_paused(false)",
		)


	func test_pause_tracks_start_frame():
		# Set up: at frame 100.
		frame_driver._is_paused = false
		frame_driver.server_frame_index = 100

		# Pause.
		frame_driver.server_set_is_paused(true)

		assert_eq(
			frame_driver.pause_start_frame,
			100,
			"Should track pause start frame",
		)


	func test_unpause_accumulates_cumulative_frames():
		# Start at frame 100, pause.
		frame_driver.server_frame_index = 100
		frame_driver._is_paused = false
		frame_driver.server_set_is_paused(true)

		# Simulate time passing (advance frame index as if paused for 30 frames).
		frame_driver.server_frame_index = 130

		# Unpause.
		frame_driver.server_set_is_paused(false)

		assert_eq(
			frame_driver._cumulative_paused_frames,
			30,
			"Should accumulate 30 paused frames",
		)


	func test_multiple_pause_cycles_accumulate():
		# Pause cycle 1: pause at 100, unpause at 120 (20 frames).
		frame_driver._is_paused = false
		frame_driver.server_frame_index = 100
		frame_driver.server_set_is_paused(true)
		frame_driver.server_frame_index = 120
		frame_driver.server_set_is_paused(false)

		# Pause cycle 2: pause at 150, unpause at 170 (20 frames).
		frame_driver.server_frame_index = 150
		frame_driver.server_set_is_paused(true)
		frame_driver.server_frame_index = 170
		frame_driver.server_set_is_paused(false)

		assert_eq(
			frame_driver._cumulative_paused_frames,
			40,
			"Should accumulate 40 paused frames across two cycles",
		)


	func test_pause_records_history():
		# Pause at 100, unpause at 120.
		frame_driver._is_paused = false
		frame_driver.server_frame_index = 100
		frame_driver.server_set_is_paused(true)
		frame_driver.server_frame_index = 120
		frame_driver.server_set_is_paused(false)

		var history := frame_driver._pause_history

		assert_eq(history.size(), 1, "Should have 1 pause entry in history")
		assert_eq(
			history[0]["start_frame"],
			100,
			"History should record start frame",
		)
		assert_eq(
			history[0]["end_frame"],
			120,
			"History should record end frame",
		)
		assert_eq(
			history[0]["duration_frames"],
			20,
			"History should record duration",
		)


	func test_pause_start_frame_returns_zero_when_not_paused():
		# Not paused.
		frame_driver._is_paused = false

		assert_eq(
			frame_driver.pause_start_frame,
			0,
			"Should return 0 when not paused",
		)


	func test_pause_clears_queued_rollback():
		# Start unpaused.
		frame_driver.server_set_is_paused(false)

		# Queue a rollback.
		frame_driver.server_frame_index = 100
		frame_driver.queue_rollback(95)

		assert_eq(
			frame_driver._queued_rollback_frame_index,
			96,
			"Rollback should be queued",
		)

		# Pause.
		frame_driver.server_set_is_paused(true)

		assert_eq(
			frame_driver._queued_rollback_frame_index,
			0,
			"Pause should clear queued rollback",
		)


	func test_idempotent_pause():
		# Pause twice.
		frame_driver._is_paused = false
		frame_driver.server_frame_index = 100
		frame_driver.server_set_is_paused(true)

		var pause_start_1 := frame_driver.pause_start_frame

		# Advance frame (shouldn't happen, but testing idempotency).
		frame_driver.server_frame_index = 110

		# Pause again (should be no-op).
		frame_driver.server_set_is_paused(true)

		assert_eq(
			frame_driver.pause_start_frame,
			pause_start_1,
			"Second pause should be no-op (idempotent)",
		)


	func test_idempotent_unpause():
		# Unpause twice.
		frame_driver._is_paused = false
		frame_driver.server_frame_index = 100

		var cumulative_before := frame_driver._cumulative_paused_frames

		# Unpause again (should be no-op).
		frame_driver.server_set_is_paused(false)

		assert_eq(
			frame_driver._cumulative_paused_frames,
			cumulative_before,
			"Second unpause should be no-op (idempotent)",
		)


	func test_pause_history_multiple_cycles():
		# Cycle 1.
		frame_driver._is_paused = false
		frame_driver.server_frame_index = 50
		frame_driver.server_set_is_paused(true)
		frame_driver.server_frame_index = 60
		frame_driver.server_set_is_paused(false)

		# Cycle 2.
		frame_driver.server_frame_index = 100
		frame_driver.server_set_is_paused(true)
		frame_driver.server_frame_index = 130
		frame_driver.server_set_is_paused(false)

		var history := frame_driver._pause_history

		assert_eq(history.size(), 2, "Should have 2 pause entries")
		assert_eq(history[0]["duration_frames"], 10, "First pause: 10 frames")
		assert_eq(history[1]["duration_frames"], 30, "Second pause: 30 frames")
