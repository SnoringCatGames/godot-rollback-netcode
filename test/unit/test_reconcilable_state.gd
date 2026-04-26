@tool
extends GutTest
## Unit tests for ReconcilableState.
##
## Phase 1 tests focus on mismatch detection - the logic that determines when
## rollbacks should trigger.

func before_each():
	ArrayPool.clear_all_pools()


func after_each():
	ArrayPool.clear_all_pools()


## Test helper that exposes protected mismatch detection for testing.
class TestableNetworkedState extends ReconcilableState:
	var test_position := Vector2.ZERO
	var test_velocity := Vector2.ZERO
	var test_health := 100
	var test_speed := 10.0
	var test_is_active := true
	var test_name := "player"

	# Allow tests to change authority.
	var _test_is_server_authoritative := true

	@warning_ignore("unused_private_class_variable") var _synced_properties_and_rollback_diff_thresholds := {
		"test_position": 1.0,
		"test_velocity": 10.0,
		"test_health": 5,
		"test_speed": 0.1,
		"test_is_active": 0,
		"test_name": 0,
	}


	func _has_non_rollbackable_interactions() -> bool:
		return false # Test class doesn't use interaction tracking.


	func _restore_indirect_interaction_state(
		_frame_state: Array,
	) -> void:
		pass


	func _init() -> void:
		super._init()
		# Initialize replication_config for programmatic instantiation.
		if replication_config == null:
			replication_config = SceneReplicationConfig.new()


	func _ready() -> void:
		super._ready()
		# In editor mode, base _ready() returns early before calling
		# _parse_property_names(). For tests, we need to parse properties
		# regardless of editor hint status.
		if Engine.is_editor_hint():
			if _rollback_buffer == null:
				_set_up_rollback_buffer()
			_parse_property_names()


	func _get_default_values() -> Array:
		return [Vector2.ZERO, Vector2.ZERO, 100, 10.0, true, "player"]


	func _get_is_server_authoritative() -> bool:
		return _test_is_server_authoritative


	func _sync_to_scene_state(_previous_state: Array) -> void:
		pass


	func _sync_from_scene_state() -> void:
		pass


	# Override _unpack_networked_state with lazy initialization for editor mode.
	func _unpack_networked_state(p_state: Array) -> void:
		# Lazy initialization: ensure properties are parsed if they haven't been yet.
		# This handles the case where _ready() returned early in editor mode.
		if _property_names_for_packing.is_empty():
			_parse_property_names()

		super._unpack_networked_state(p_state)


	# Override _parse_property_names to work around @tool + inner class issues.
	func _parse_property_names() -> void:
		# Directly access the var instead of using get() which may fail
		# in @tool mode with inner classes.
		var keys = _synced_properties_and_rollback_diff_thresholds.keys()

		# Clear and manually populate to ensure typed array works correctly.
		_property_names_for_packing.clear()
		for key in keys:
			_property_names_for_packing.append(key)

		_property_name_to_pack_index.clear()
		for i in range(_property_names_for_packing.size()):
			var property_name := _property_names_for_packing[i]
			_property_name_to_pack_index[property_name] = i


	# Expose protected methods for testing.
	func check_do_values_mismatch_public(
			buffer_value: Variant,
			networked_value: Variant,
			threshold: Variant,
	) -> bool:
		return _check_do_values_mismatch(buffer_value, networked_value, threshold)


	func pack_networked_state_public() -> void:
		_pack_networked_state()


	func unpack_networked_state_public() -> void:
		_unpack_networked_state(authoritative_packed_state)


	func pack_buffer_state_from_network_state_public(
			packed_network_state: Array,
	) -> void:
		_pack_buffer_state_from_network_state(packed_network_state)


class TestMismatchDetection:
	extends GutTest
	## Tests type-specific threshold comparison logic - determines when
	## rollbacks trigger.

	var entity: TestableNetworkedState


	func before_each():
		ArrayPool.clear_all_pools()
		entity = TestableNetworkedState.new()


	func after_each():
		ArrayPool.clear_all_pools()
		if is_instance_valid(entity):
			entity.free()


	func test_check_do_values_mismatch_vector2_above_threshold():
		# Distance = 5 pixels, threshold = 1.0
		# distance_squared = 25, threshold_squared = 1
		# 25 >= 1 -> mismatch.
		var buffer_value := Vector2(100.0, 50.0)
		var network_value := Vector2(105.0, 50.0)
		var threshold := 1.0

		var result := entity.check_do_values_mismatch_public(
			buffer_value,
			network_value,
			threshold,
		)

		assert_true(result, "5 pixel difference should exceed 1.0 threshold")


	func test_check_do_values_mismatch_vector2_below_threshold():
		# Distance = 0.5 pixels, threshold = 1.0
		# distance_squared = 0.25, threshold_squared = 1
		# 0.25 < 1 -> no mismatch.
		var buffer_value := Vector2(100.0, 50.0)
		var network_value := Vector2(100.5, 50.0)
		var threshold := 1.0

		var result := entity.check_do_values_mismatch_public(
			buffer_value,
			network_value,
			threshold,
		)

		assert_false(result, "0.5 pixel difference should not exceed 1.0 threshold")


	func test_check_do_values_mismatch_vector2_exact_threshold():
		# Distance = 1.0 pixel, threshold = 1.0
		# distance_squared = 1, threshold_squared = 1
		# 1 >= 1 -> mismatch (boundary case).
		var buffer_value := Vector2(100.0, 50.0)
		var network_value := Vector2(101.0, 50.0)
		var threshold := 1.0

		var result := entity.check_do_values_mismatch_public(
			buffer_value,
			network_value,
			threshold,
		)

		assert_true(result, "Exact threshold distance should trigger mismatch (>=)")


	func test_check_do_values_mismatch_vector2_zero_threshold_exact_match():
		# Threshold 0 requires exact match.
		var buffer_value := Vector2(100.0, 50.0)
		var network_value := Vector2(100.0, 50.0)
		var threshold := 0.0

		var result := entity.check_do_values_mismatch_public(
			buffer_value,
			network_value,
			threshold,
		)

		assert_false(result, "Exact match with zero threshold should not mismatch")


	func test_check_do_values_mismatch_vector2_zero_threshold_different():
		# Threshold 0 requires exact match. Any difference is a mismatch.
		var buffer_value := Vector2(100.0, 50.0)
		var network_value := Vector2(100.01, 50.0)
		var threshold := 0.0

		var result := entity.check_do_values_mismatch_public(
			buffer_value,
			network_value,
			threshold,
		)

		assert_true(result, "Any difference with zero threshold should mismatch")


	func test_check_do_values_mismatch_float_above_threshold():
		# abs(10.5 - 10.0) = 0.5 >= 0.1 -> mismatch.
		var buffer_value := 10.0
		var network_value := 10.5
		var threshold := 0.1

		var result := entity.check_do_values_mismatch_public(
			buffer_value,
			network_value,
			threshold,
		)

		assert_true(result, "Float difference 0.5 should exceed 0.1 threshold")


	func test_check_do_values_mismatch_float_below_threshold():
		# abs(10.05 - 10.0) = 0.05 < 0.1 -> no mismatch.
		var buffer_value := 10.0
		var network_value := 10.05
		var threshold := 0.1

		var result := entity.check_do_values_mismatch_public(
			buffer_value,
			network_value,
			threshold,
		)

		assert_false(result, "Float difference 0.05 should not exceed 0.1 threshold")


	func test_check_do_values_mismatch_float_zero_threshold_exact_match():
		# Threshold 0 requires exact match.
		var buffer_value := 10.0
		var network_value := 10.0
		var threshold := 0.0

		var result := entity.check_do_values_mismatch_public(
			buffer_value,
			network_value,
			threshold,
		)

		assert_false(result, "Exact float match with zero threshold should not mismatch")


	func test_check_do_values_mismatch_int_above_threshold():
		# abs(105 - 100) = 5 >= 5 -> mismatch.
		var buffer_value := 100
		var network_value := 105
		var threshold := 5

		var result := entity.check_do_values_mismatch_public(
			buffer_value,
			network_value,
			threshold,
		)

		assert_true(result, "Int difference 5 should meet 5 threshold")


	func test_check_do_values_mismatch_int_below_threshold():
		# abs(103 - 100) = 3 < 5 -> no mismatch.
		var buffer_value := 100
		var network_value := 103
		var threshold := 5

		var result := entity.check_do_values_mismatch_public(
			buffer_value,
			network_value,
			threshold,
		)

		assert_false(result, "Int difference 3 should not exceed 5 threshold")


	func test_check_do_values_mismatch_bool_different():
		# Booleans must match exactly.
		var buffer_value := true
		var network_value := false
		var threshold := 0 # Threshold not used for booleans

		var result := entity.check_do_values_mismatch_public(
			buffer_value,
			network_value,
			threshold,
		)

		assert_true(result, "Different boolean values should mismatch")


	func test_check_do_values_mismatch_bool_same():
		# Verify no false positive when booleans match.
		var buffer_value := true
		var network_value := true
		var threshold := 0

		var result := entity.check_do_values_mismatch_public(
			buffer_value,
			network_value,
			threshold,
		)

		assert_false(result, "Matching boolean values should not mismatch")


	func test_check_do_values_mismatch_string_different():
		# Strings must match exactly.
		var buffer_value := "player1"
		var network_value := "player2"
		var threshold := 0 # Threshold not used for strings

		var result := entity.check_do_values_mismatch_public(
			buffer_value,
			network_value,
			threshold,
		)

		assert_true(result, "Different string values should mismatch")


	func test_check_do_values_mismatch_string_same():
		# Verify no false positive when strings match.
		var buffer_value := "player1"
		var network_value := "player1"
		var threshold := 0

		var result := entity.check_do_values_mismatch_public(
			buffer_value,
			network_value,
			threshold,
		)

		assert_false(result, "Matching string values should not mismatch")


class TestStatePacking:
	extends GutTest
	## Tests serialization with ArrayPool memory management.

	var entity: TestableNetworkedState
	var root_node: Node


	func before_each():
		ArrayPool.clear_all_pools()

		# Create root node for entity.
		root_node = Node.new()
		root_node.name = "Root"
		add_child_autofree(root_node)

		# Create entity as child of root.
		entity = TestableNetworkedState.new()
		entity.name = "TestEntity"
		entity.root_path = NodePath(".")
		root_node.add_child(entity)

		# Initialize entity.
		entity._ready()
		# Explicitly ensure rollback buffer and property names are initialized
		# (in case _ready() was already called during @tool execution).
		if entity._rollback_buffer == null:
			entity._set_up_rollback_buffer()
		# Always re-parse property names to ensure they're up to date.
		entity._parse_property_names()


	func after_each():
		ArrayPool.clear_all_pools()


	func test_pack_networked_state_creates_array_from_pool():
		# Set entity properties.
		entity.test_position = Vector2(100.0, 50.0)
		entity.test_velocity = Vector2(10.0, 5.0)
		entity.test_health = 95
		entity.frame_index = 42

		# Pack state.
		entity.pack_networked_state_public()

		# Verify authoritative_packed_state is not empty and has correct size.
		# 6 properties + frame_authority + timestamp = 8 elements.
		assert_not_null(
			entity.authoritative_packed_state,
			"authoritative_packed_state should not be null",
		)
		assert_eq(
			entity.authoritative_packed_state.size(),
			8,
			"authoritative_packed_state should have 8 elements",
		)


	func test_pack_networked_state_includes_frame_index():
		# Set entity properties and frame index.
		entity.frame_index = 100

		# Pack state.
		entity.pack_networked_state_public()

		# Last element should be frame index directly.
		var packed_frame_index: int = (
			entity.authoritative_packed_state[
				entity.authoritative_packed_state
					.size() - 1
			]
		)

		assert_eq(
			packed_frame_index,
			100,
			"Last element should be frame index",
		)


	func test_pack_networked_state_releases_old_array():
		# Pack state twice to verify old array is released.
		entity.test_position = Vector2(100.0, 50.0)
		entity.frame_index = 10

		entity.pack_networked_state_public()
		var first_packed := entity.authoritative_packed_state

		# Change state and pack again.
		entity.test_position = Vector2(200.0, 100.0)
		entity.frame_index = 20

		entity.pack_networked_state_public()
		var second_packed := entity.authoritative_packed_state

		# Arrays should be different instances.
		assert_ne(
			first_packed,
			second_packed,
			"Second pack should create new array",
		)
		# Old array should be released to pool (can't directly verify,
		# but no memory leak should occur.)


	func test_unpack_networked_state_restores_properties():
		# First, set properties and pack to get the correct property order.
		entity.test_position = Vector2(123.0, 456.0)
		entity.test_velocity = Vector2(10.0, 20.0)
		entity.test_health = 85
		entity.test_speed = 15.5
		entity.test_is_active = false
		entity.test_name = "test_player"
		entity.frame_index = 50

		# Pack to create properly ordered state.
		entity.pack_networked_state_public()
		var packed_state_to_restore := entity.authoritative_packed_state

		# Verify pack worked.
		assert_not_null(
			packed_state_to_restore,
			"Packed state should not be null",
		)
		assert_eq(
			packed_state_to_restore.size(),
			8,
			"Packed state should have 8 elements",
		)

		# Now reset properties to defaults.
		entity.test_position = Vector2.ZERO
		entity.test_velocity = Vector2.ZERO
		entity.test_health = 100
		entity.test_speed = 10.0
		entity.test_is_active = true
		entity.test_name = "player"

		# Set the _is_packing_state_locally flag to prevent the setter from
		# triggering _handle_new_state_from_network() which would unpack
		# the state automatically before we can test the unpacking
		# explicitly.
		entity._is_packing_state_locally = true
		entity.authoritative_packed_state = packed_state_to_restore
		entity._is_packing_state_locally = false

		# Verify state is still valid before unpacking.
		assert_eq(
			entity.authoritative_packed_state.size(),
			8,
			"Packed state should still have 8 elements before unpack",
		)

		entity.unpack_networked_state_public()

		# Verify properties were restored.
		assert_eq(
			entity.test_position,
			Vector2(123.0, 456.0),
			"Position should be restored",
		)
		assert_eq(
			entity.test_velocity,
			Vector2(10.0, 20.0),
			"Velocity should be restored",
		)
		assert_eq(entity.test_health, 85, "Health should be restored")
		assert_eq(entity.test_speed, 15.5, "Speed should be restored")
		assert_eq(
			entity.test_is_active,
			false,
			"Is active should be restored",
		)
		assert_eq(
			entity.test_name,
			"test_player",
			"Name should be restored",
		)


	func test_unpack_networked_state_handles_empty_array():
		# Set authoritative_packed_state to empty and unpack.
		entity.authoritative_packed_state = []

		# Should not crash.
		entity.unpack_networked_state_public()

		# Properties should remain at default values.
		assert_eq(
			entity.test_position,
			Vector2.ZERO,
			"Position should remain default",
		)


	func test_pack_buffer_state_from_network_state_converts_authority():
		# Use a frame near the buffer's current state.
		var base_frame := entity._rollback_buffer.get_latest_index() + 1

		# Create packed network state (6 properties + frame_authority + frame_index).
		var network_state := ArrayPool.acquire(8)
		network_state[0] = Vector2(100.0, 50.0)
		network_state[1] = Vector2(5.0, 2.0)
		network_state[2] = 90
		network_state[3] = 12.0
		network_state[4] = true
		network_state[5] = "player"
		network_state[6] = ReconcilableState.FrameAuthority.AUTHORITATIVE
		network_state[7] = base_frame

		# Pack into buffer.
		entity.pack_buffer_state_from_network_state_public(network_state)

		# Verify buffer state was created with AUTHORITATIVE marker.
		var buffer_state: Array = entity._rollback_buffer.get_at(base_frame)

		# Last element should be FrameAuthority.AUTHORITATIVE (1).
		assert_eq(
			buffer_state[buffer_state.size() - 1],
			ReconcilableState.FrameAuthority.AUTHORITATIVE,
			"Buffer state should have AUTHORITATIVE marker",
		)


	func test_pack_and_unpack_round_trip():
		# Set entity properties.
		entity.test_position = Vector2(200.0, 300.0)
		entity.test_velocity = Vector2(15.0, 25.0)
		entity.test_health = 75
		entity.test_speed = 8.5
		entity.test_is_active = false
		entity.test_name = "round_trip_test"
		entity.frame_index = 55

		# Pack and unpack.
		entity.pack_networked_state_public()
		var packed_copy := entity.authoritative_packed_state.duplicate()

		# Verify pack worked.
		assert_not_null(packed_copy, "Packed copy should not be null")
		assert_eq(
			packed_copy.size(),
			8,
			"Packed copy should have 8 elements",
		)

		# Clear properties.
		entity.test_position = Vector2.ZERO
		entity.test_velocity = Vector2.ZERO
		entity.test_health = 0
		entity.test_speed = 0.0
		entity.test_is_active = true
		entity.test_name = ""

		# Set flag to prevent automatic unpacking.
		entity._is_packing_state_locally = true
		entity.authoritative_packed_state = packed_copy
		entity._is_packing_state_locally = false

		# Verify state is still valid before unpacking.
		assert_eq(
			entity.authoritative_packed_state.size(),
			8,
			"Packed state should still have 8 elements before unpack",
		)

		entity.unpack_networked_state_public()

		# Verify all properties restored correctly.
		assert_eq(
			entity.test_position,
			Vector2(200.0, 300.0),
			"Position round-trip",
		)
		assert_eq(
			entity.test_velocity,
			Vector2(15.0, 25.0),
			"Velocity round-trip",
		)
		assert_eq(entity.test_health, 75, "Health round-trip")
		assert_eq(entity.test_speed, 8.5, "Speed round-trip")
		assert_eq(entity.test_is_active, false, "Is active round-trip")
		assert_eq(entity.test_name, "round_trip_test", "Name round-trip")


class TestBufferStateRestoration:
	extends GutTest
	## Tests rollback state synchronization.

	var entity: TestableNetworkedState
	var root_node: Node


	func before_each():
		ArrayPool.clear_all_pools()

		root_node = Node.new()
		root_node.name = "Root"
		add_child_autofree(root_node)

		entity = TestableNetworkedState.new()
		entity.name = "TestEntity"
		entity.root_path = NodePath(".")
		root_node.add_child(entity)

		# Initialize entity.
		entity._ready()
		# Explicitly ensure rollback buffer and property names are initialized
		# (in case _ready() was already called during @tool execution).
		if entity._rollback_buffer == null:
			entity._set_up_rollback_buffer()
		# Always re-parse property names to ensure they're up to date.
		entity._parse_property_names()


	func after_each():
		ArrayPool.clear_all_pools()


	func test_record_buffer_frame_stores_state():
		# Use the buffer's current latest index + 1.
		var test_frame := entity._rollback_buffer.get_latest_index() + 1

		# Create a state to record.
		var frame_state := ArrayPool.acquire(7)
		frame_state[0] = Vector2(100.0, 200.0)
		frame_state[1] = Vector2(10.0, 20.0)
		frame_state[2] = 85
		frame_state[3] = 12.0
		frame_state[4] = true
		frame_state[5] = "test"
		frame_state[6] = ReconcilableState.FrameAuthority.CLIENT_PREDICTED

		# Record at test frame.
		entity._record_buffer_frame(test_frame, frame_state)

		# Verify it was stored.
		assert_true(
			entity._rollback_buffer.has_at(test_frame),
			"Should have state at frame %d" % test_frame,
		)


	func test_unpack_buffer_state_restores_properties():
		# Use the buffer's current latest index + 1.
		var test_frame := entity._rollback_buffer.get_latest_index() + 1

		# Store state in buffer.
		var frame_state := ArrayPool.acquire(7)
		frame_state[0] = Vector2(150.0, 250.0)
		frame_state[1] = Vector2(15.0, 25.0)
		frame_state[2] = 90
		frame_state[3] = 13.5
		frame_state[4] = false
		frame_state[5] = "restored"
		frame_state[6] = ReconcilableState.FrameAuthority.AUTHORITATIVE

		entity._rollback_buffer.set_at(test_frame, frame_state)

		# Unpack from buffer.
		entity._unpack_buffer_state(test_frame)

		# Verify properties were restored.
		assert_eq(
			entity.test_position,
			Vector2(150.0, 250.0),
			"Position should be restored from buffer",
		)
		assert_eq(
			entity.frame_authority,
			ReconcilableState.FrameAuthority.AUTHORITATIVE,
			"Frame authority should be restored",
		)


	func test_backfill_creates_intermediate_frames():
		# Use frames relative to buffer's current state.
		var base_frame := entity._rollback_buffer.get_latest_index()
		var frame_a := base_frame + 1
		var frame_b := base_frame + 6

		# Record state at frame_a.
		var state_a := ArrayPool.acquire(7)
		state_a[0] = Vector2(10.0, 10.0)
		state_a[1] = Vector2.ZERO
		state_a[2] = 100
		state_a[3] = 10.0
		state_a[4] = true
		state_a[5] = "frame_a"
		state_a[6] = ReconcilableState.FrameAuthority.CLIENT_PREDICTED

		entity._rollback_buffer.set_at(frame_a, state_a)

		# Record state at frame_b with backfill.
		var state_b := ArrayPool.acquire(7)
		state_b[0] = Vector2(15.0, 15.0)
		state_b[1] = Vector2.ZERO
		state_b[2] = 100
		state_b[3] = 10.0
		state_b[4] = true
		state_b[5] = "frame_b"
		state_b[6] = ReconcilableState.FrameAuthority.CLIENT_PREDICTED

		entity._record_buffer_frame(frame_b, state_b)

		# Intermediate frames should now exist (backfilled from frame_a).
		for i in range(frame_a + 1, frame_b):
			assert_true(
				entity._rollback_buffer.has_at(i),
				"Frame %d should be backfilled" % i,
			)


	func test_frame_authority_restores_from_buffer():
		# When _pre_network_process is called, frame_authority
		# is first set to UNKNOWN, then restored from the
		# rollback buffer. The buffer default depends on
		# Netcode.is_server (SERVER_PREDICTED when true,
		# CLIENT_PREDICTED when false).
		entity.frame_authority = (
			ReconcilableState.FrameAuthority.AUTHORITATIVE
		)

		var expected_authority: int = (
			ReconcilableState.FrameAuthority.SERVER_PREDICTED
			if Netcode.is_server
			else ReconcilableState.FrameAuthority
				.CLIENT_PREDICTED
		)

		# Call the real production method.
		entity._pre_network_process()

		assert_eq(
			entity.frame_authority,
			expected_authority,
			"Frame authority should restore from buffer",
		)


	func test_frame_index_updates_during_pre_network_process():
		# Set server frame index on the frame driver
		# (Netcode.server_frame_index is read-only).
		var original := (
			Netcode.frame_driver.server_frame_index)
		Netcode.frame_driver.server_frame_index = 42

		entity._pre_network_process()

		assert_eq(
			entity.frame_index,
			42,
			"Timestamp index should match server frame index",
		)

		# Restore original value.
		Netcode.frame_driver.server_frame_index = original


	func test_has_authoritative_state_for_current_frame():
		# Use the buffer's current latest index + 1.
		var test_frame := entity._rollback_buffer.get_latest_index() + 1

		var state := ArrayPool.acquire(7)
		state[0] = Vector2.ZERO
		state[1] = Vector2.ZERO
		state[2] = 100
		state[3] = 10.0
		state[4] = true
		state[5] = "test"
		state[6] = ReconcilableState.FrameAuthority.AUTHORITATIVE

		entity._rollback_buffer.set_at(test_frame, state)

		# Verify the state was stored with AUTHORITATIVE marker.
		assert_true(
			entity._rollback_buffer.has_at(test_frame),
			"Buffer should have test frame",
		)

		var retrieved_state: Array = entity._rollback_buffer.get_at(test_frame)
		var authority := (
			retrieved_state[retrieved_state.size() - 1] as ReconcilableState.FrameAuthority
		)

		assert_eq(
			authority,
			ReconcilableState.FrameAuthority.AUTHORITATIVE,
			"Frame should have AUTHORITATIVE marker",
		)


	func test_does_not_have_authoritative_state_when_predicted():
		# Store predicted state for current frame.
		Netcode.server_frame_index = 50
		var state := ArrayPool.acquire(7)
		state[0] = Vector2.ZERO
		state[1] = Vector2.ZERO
		state[2] = 100
		state[3] = 10.0
		state[4] = true
		state[5] = "test"
		state[6] = ReconcilableState.FrameAuthority.CLIENT_PREDICTED

		entity._rollback_buffer.set_at(50, state)

		# Check for authoritative state.
		var has_auth := entity._has_authoritative_state_for_current_frame()

		assert_false(
			has_auth,
			"Should not have authoritative state when predicted",
		)


class TestPropertyConfiguration:
	extends GutTest
	## Tests property name parsing and validation.

	var entity: TestableNetworkedState
	var root_node: Node


	func before_each():
		ArrayPool.clear_all_pools()

		root_node = Node.new()
		root_node.name = "Root"
		add_child_autofree(root_node)

		entity = TestableNetworkedState.new()
		entity.name = "TestEntity"
		entity.root_path = NodePath(".")
		root_node.add_child(entity)

		# Initialize entity.
		entity._ready()
		# Explicitly ensure rollback buffer and property names are initialized
		# (in case _ready() was already called during @tool execution).
		if entity._rollback_buffer == null:
			entity._set_up_rollback_buffer()
		# Always re-parse property names to ensure they're up to date.
		entity._parse_property_names()


	func after_each():
		ArrayPool.clear_all_pools()


	func test_parse_property_names_from_threshold_dictionary():
		# Parse property names.
		entity._parse_property_names()

		# Should have 6 properties.
		assert_eq(
			entity._property_names_for_packing.size(),
			6,
			"Should have 6 properties",
		)

		# Should contain expected property names.
		assert_true(
			entity._property_names_for_packing.has("test_position"),
			"Should have test_position",
		)
		assert_true(
			entity._property_names_for_packing.has("test_velocity"),
			"Should have test_velocity",
		)


	func test_property_name_to_pack_index_mapping():
		# Parse property names to build index mapping.
		entity._parse_property_names()

		# Verify mapping contains correct indices.
		assert_true(
			entity._property_name_to_pack_index.has("test_position"),
			"Should have index for test_position",
		)

		var position_index: int = (
			entity._property_name_to_pack_index["test_position"]
		)
		assert_gte(
			position_index,
			0,
			"Position index should be >= 0",
		)
		assert_lt(
			position_index,
			6,
			"Position index should be < 6",
		)


	func test_get_configuration_warnings_empty_root_path():
		# Create entity with empty root_path.
		var bad_entity := TestableNetworkedState.new()
		bad_entity.root_path = NodePath()
		root_node.add_child(bad_entity)

		# Get warnings.
		var warnings := bad_entity._get_configuration_warnings()

		# Should have warning about empty root_path.
		assert_gt(
			warnings.size(),
			0,
			"Should have at least one warning",
		)

		var has_root_path_warning := false
		for warning in warnings:
			if "root_path" in warning:
				has_root_path_warning = true
				break

		assert_true(
			has_root_path_warning,
			"Should have warning about root_path",
		)

		bad_entity.queue_free()


	func test_property_packing_order_is_consistent():
		# Parse property names twice.
		entity._parse_property_names()
		var first_names := entity._property_names_for_packing.duplicate()

		# Clear and parse again.
		entity._property_names_for_packing.clear()
		entity._property_name_to_pack_index.clear()
		entity._parse_property_names()
		var second_names := entity._property_names_for_packing

		# Order should be consistent.
		assert_eq(
			first_names,
			second_names,
			"Property packing order should be consistent",
		)


	func test_get_string_for_packed_state():
		# Create a packed state.
		var packed := [
			Vector2(100.0, 50.0),
			Vector2(10.0, 5.0),
			95,
			12.5,
			true,
			"player",
			100000,
		]

		# Get string representation.
		var str_repr := entity.get_string_for_packed_state(packed)

		# Should be a non-empty string with array format.
		assert_ne(str_repr, "", "Should return non-empty string")
		assert_true(
			str_repr.begins_with("["),
			"Should start with '['",
		)
		assert_true(str_repr.ends_with("]"), "Should end with ']'")


	func test_record_initial_state_populates_buffer_frames():
		# Set properties to specific values.
		entity.test_position = Vector2(50.0, 100.0)
		entity.test_velocity = Vector2(5.0, 10.0)
		entity.test_health = 80
		entity.test_speed = 15.0
		entity.test_is_active = true
		entity.test_name = "initialized"

		# Record initial state.
		var current_frame := Netcode.server_frame_index
		entity.record_initial_state()

		# Frames N-2, N-1, and N should all exist.
		assert_true(
			entity._rollback_buffer.has_at(current_frame - 2),
			"Frame N-2 should exist",
		)
		assert_true(
			entity._rollback_buffer.has_at(current_frame - 1),
			"Frame N-1 should exist",
		)
		assert_true(
			entity._rollback_buffer.has_at(current_frame),
			"Frame N should exist",
		)


	func test_record_initial_state_preserves_property_values():
		# Set specific values.
		entity.test_position = Vector2(123.0, 456.0)
		entity.test_velocity = Vector2(12.0, 34.0)
		entity.test_health = 95

		# Record initial state.
		var current_frame := Netcode.server_frame_index
		entity.record_initial_state()

		# Retrieve state from frame N.
		var frame_state: Array = entity._rollback_buffer.get_at(current_frame)

		# Verify property values are preserved (order depends on property
		# packing).
		var position_index: int = (
			entity._property_name_to_pack_index["test_position"]
		)
		var velocity_index: int = (
			entity._property_name_to_pack_index["test_velocity"]
		)
		var health_index: int = (
			entity._property_name_to_pack_index["test_health"]
		)

		assert_eq(
			frame_state[position_index],
			Vector2(123.0, 456.0),
			"Position should be preserved",
		)
		assert_eq(
			frame_state[velocity_index],
			Vector2(12.0, 34.0),
			"Velocity should be preserved",
		)
		assert_eq(
			frame_state[health_index],
			95,
			"Health should be preserved",
		)


	func test_record_initial_state_marks_frames_as_predicted():
		# Record initial state.
		var current_frame := Netcode.server_frame_index
		entity.record_initial_state()

		# All frames should be marked as SERVER_PREDICTED (tests run as server).
		for frame_offset in range(-2, 1):
			var target_frame := current_frame + frame_offset
			var frame_state: Array = (
				entity._rollback_buffer.get_at(target_frame)
			)
			var authority := (
				frame_state[frame_state.size() - 1] as ReconcilableState.FrameAuthority
			)

			assert_eq(
				authority,
				ReconcilableState.FrameAuthority.SERVER_PREDICTED,
				"Frame %d should be marked as SERVER_PREDICTED" % target_frame,
			)
