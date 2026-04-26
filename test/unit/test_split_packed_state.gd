@tool
extends GutTest
## Unit tests for the split packed state feature
## (predicted_packed_state + authoritative_packed_state).


func before_each():
	ArrayPool.clear_all_pools()


func after_each():
	ArrayPool.clear_all_pools()


## Test entity that does NOT use split packed state (default behavior).
class NonSplitEntity extends ReconcilableState:
	var test_position := Vector2.ZERO
	var test_velocity := Vector2.ZERO

	@warning_ignore("unused_private_class_variable")
	var _synced_properties_and_rollback_diff_thresholds := {
		"test_position": 1.0,
		"test_velocity": 0.5,
	}


	func _has_non_rollbackable_interactions() -> bool:
		return false


	func _restore_indirect_interaction_state(
		_frame_state: Array,
	) -> void:
		pass


	func _init() -> void:
		super._init()
		if replication_config == null:
			replication_config = SceneReplicationConfig.new()


	func _get_default_values() -> Array:
		return [Vector2.ZERO, Vector2.ZERO]


	func _get_is_server_authoritative() -> bool:
		return true


	func _sync_to_scene_state(_previous_state: Array) -> void:
		pass


	func _sync_from_scene_state() -> void:
		pass


	func _parse_property_names() -> void:
		var keys = _synced_properties_and_rollback_diff_thresholds.keys()
		_property_names_for_packing.clear()
		for key in keys:
			_property_names_for_packing.append(key)
		_property_name_to_pack_index.clear()
		for i in range(_property_names_for_packing.size()):
			_property_name_to_pack_index[_property_names_for_packing[i]] = i


## Test entity that uses split packed state.
class SplitEntity extends ReconcilableState:
	var test_position := Vector2.ZERO
	var test_velocity := Vector2.ZERO

	@warning_ignore("unused_private_class_variable")
	var _synced_properties_and_rollback_diff_thresholds := {
		"test_position": 1.0,
		"test_velocity": 0.5,
	}


	func _has_non_rollbackable_interactions() -> bool:
		return false


	func _restore_indirect_interaction_state(
		_frame_state: Array,
	) -> void:
		pass


	func _init() -> void:
		super._init()
		if replication_config == null:
			replication_config = SceneReplicationConfig.new()


	func _get_default_values() -> Array:
		return [Vector2.ZERO, Vector2.ZERO]


	func _get_is_server_authoritative() -> bool:
		return true


	func _uses_split_packed_state() -> bool:
		return true


	func _should_accept_predicted_states() -> bool:
		return true


	func _sync_to_scene_state(_previous_state: Array) -> void:
		pass


	func _sync_from_scene_state() -> void:
		pass


	func _parse_property_names() -> void:
		var keys = _synced_properties_and_rollback_diff_thresholds.keys()
		_property_names_for_packing.clear()
		for key in keys:
			_property_names_for_packing.append(key)
		_property_name_to_pack_index.clear()
		for i in range(_property_names_for_packing.size()):
			_property_name_to_pack_index[_property_names_for_packing[i]] = i


class TestSplitPackedStateDefault:
	extends GutTest
	## Tests that _uses_split_packed_state() defaults to false.

	func before_each():
		ArrayPool.clear_all_pools()

	func after_each():
		ArrayPool.clear_all_pools()


	func test_default_uses_split_packed_state_is_false():
		var entity := NonSplitEntity.new()
		add_child_autofree(entity)
		assert_false(
			entity._uses_split_packed_state(),
			"Default should not use split packed state",
		)


	func test_split_entity_uses_split_packed_state_is_true():
		var entity := SplitEntity.new()
		add_child_autofree(entity)
		assert_true(
			entity._uses_split_packed_state(),
			"SplitEntity should use split packed state",
		)


class TestNonSplitPacking:
	extends GutTest
	## Tests that non-split entities pack to authoritative_packed_state.

	var entity: NonSplitEntity
	var root_node: Node

	func before_each():
		ArrayPool.clear_all_pools()

		root_node = Node.new()
		root_node.name = "Root"
		add_child_autofree(root_node)

		entity = NonSplitEntity.new()
		entity.name = "TestEntity"
		entity.root_path = NodePath("..")
		root_node.add_child(entity)

		entity._ready()
		if entity._rollback_buffer == null:
			entity._set_up_rollback_buffer()
		entity._parse_property_names()


	func after_each():
		ArrayPool.clear_all_pools()


	func test_pack_writes_to_authoritative_packed_state():
		entity.test_position = Vector2(100.0, 50.0)
		entity.test_velocity = Vector2(10.0, 5.0)
		entity.frame_index = 42

		entity._pack_networked_state()

		assert_false(
			entity.authoritative_packed_state.is_empty(),
			"authoritative_packed_state should be populated",
		)
		# 2 properties + frame_authority + frame_index = 4.
		assert_eq(
			entity.authoritative_packed_state.size(),
			4,
			"authoritative_packed_state should have 4 elements",
		)


	func test_pack_does_not_write_to_predicted_packed_state():
		entity.test_position = Vector2(100.0, 50.0)
		entity.frame_index = 42

		entity._pack_networked_state()

		assert_true(
			entity.predicted_packed_state.is_empty(),
			"predicted_packed_state should remain empty "
			+ "for non-split entity",
		)


class TestSplitPacking:
	extends GutTest
	## Tests that split entities pack to predicted_packed_state.

	var entity: SplitEntity
	var root_node: Node

	func before_each():
		ArrayPool.clear_all_pools()

		root_node = Node.new()
		root_node.name = "Root"
		add_child_autofree(root_node)

		entity = SplitEntity.new()
		entity.name = "TestEntity"
		entity.root_path = NodePath("..")
		root_node.add_child(entity)

		entity._ready()
		if entity._rollback_buffer == null:
			entity._set_up_rollback_buffer()
		entity._parse_property_names()


	func after_each():
		ArrayPool.clear_all_pools()


	func test_pack_writes_to_predicted_packed_state():
		entity.test_position = Vector2(100.0, 50.0)
		entity.test_velocity = Vector2(10.0, 5.0)
		entity.frame_index = 42

		entity._pack_networked_state()

		assert_false(
			entity.predicted_packed_state.is_empty(),
			"predicted_packed_state should be populated",
		)
		assert_eq(
			entity.predicted_packed_state.size(),
			4,
			"predicted_packed_state should have 4 elements",
		)


	func test_pack_does_not_write_to_authoritative_packed_state():
		entity.test_position = Vector2(100.0, 50.0)
		entity.frame_index = 42

		entity._pack_networked_state()

		assert_true(
			entity.authoritative_packed_state.is_empty(),
			"authoritative_packed_state should remain empty "
			+ "after normal packing",
		)


	func test_pack_includes_correct_values():
		entity.test_position = Vector2(200.0, 300.0)
		entity.test_velocity = Vector2(15.0, 25.0)
		entity.frame_index = 55
		entity.frame_authority = (
			ReconcilableState.FrameAuthority
				.SERVER_PREDICTED
		)

		entity._pack_networked_state()

		var state: Array = entity.predicted_packed_state
		assert_eq(state[0], Vector2(200.0, 300.0), "Position value")
		assert_eq(state[1], Vector2(15.0, 25.0), "Velocity value")
		assert_eq(
			state[2],
			ReconcilableState.FrameAuthority.SERVER_PREDICTED,
			"Authority value",
		)
		assert_eq(state[3], 55, "Frame index value")


	func test_pack_releases_old_predicted_packed_state():
		entity.test_position = Vector2(100.0, 50.0)
		entity.frame_index = 10

		entity._pack_networked_state()
		var first_state: Array = entity.predicted_packed_state

		entity.test_position = Vector2(200.0, 100.0)
		entity.frame_index = 20

		entity._pack_networked_state()
		var second_state: Array = entity.predicted_packed_state

		# Should be different array instances.
		assert_ne(
			first_state,
			second_state,
			"Second pack should create new array",
		)


class TestReceivePath:
	extends GutTest
	## Tests that setting predicted_packed_state or
	## authoritative_packed_state triggers the network handler
	## and stores state in the rollback buffer.

	var entity: SplitEntity
	var root_node: Node

	func before_each():
		ArrayPool.clear_all_pools()

		root_node = Node.new()
		root_node.name = "Root"
		add_child_autofree(root_node)

		entity = SplitEntity.new()
		entity.name = "TestEntity"
		entity.root_path = NodePath("..")
		root_node.add_child(entity)

		entity._ready()
		if entity._rollback_buffer == null:
			entity._set_up_rollback_buffer()
		entity._parse_property_names()

		# Unpause so state reception is not
		# filtered by pause logic.
		Netcode.frame_driver._is_paused = false


	func after_each():
		ArrayPool.clear_all_pools()


	func test_predicted_setter_stores_in_buffer():
		# Simulate a network receive (not local packing).
		var frame := entity._rollback_buffer.get_latest_index() + 1
		var state := [
			Vector2(100.0, 50.0),
			Vector2(10.0, 5.0),
			ReconcilableState.FrameAuthority.SERVER_PREDICTED,
			frame,
		]

		entity.predicted_packed_state = state

		assert_true(
			entity._rollback_buffer.has_at(frame),
			"Buffer should have state at frame %d" % frame,
		)


	func test_predicted_setter_does_not_unpack_when_packing_locally():
		entity._is_packing_state_locally = true
		var state := [
			Vector2(100.0, 50.0),
			Vector2(10.0, 5.0),
			ReconcilableState.FrameAuthority.SERVER_PREDICTED,
			42,
		]

		entity.predicted_packed_state = state

		# State should be stored but handler should NOT run.
		assert_eq(
			entity.predicted_packed_state,
			state,
			"predicted_packed_state should be stored",
		)

		entity._is_packing_state_locally = false


	func test_authoritative_setter_does_not_unpack_when_packing_locally():
		entity._is_packing_state_locally = true
		var state := [
			Vector2(100.0, 50.0),
			Vector2(10.0, 5.0),
			ReconcilableState.FrameAuthority.AUTHORITATIVE,
			42,
		]

		entity.authoritative_packed_state = state

		# State should be stored but handler should NOT run.
		assert_eq(
			entity.authoritative_packed_state,
			state,
			"authoritative_packed_state should be stored",
		)

		entity._is_packing_state_locally = false


	func test_authoritative_state_stores_in_buffer():
		# Send authoritative state for a frame in the buffer range.
		var frame := entity._rollback_buffer.get_latest_index() + 1
		var state := [
			Vector2(200.0, 300.0),
			Vector2(15.0, 25.0),
			ReconcilableState.FrameAuthority.AUTHORITATIVE,
			frame,
		]

		entity.authoritative_packed_state = state

		# Verify the buffer has the state.
		assert_true(
			entity._rollback_buffer.has_at(frame),
			"Buffer should have state at frame %d" % frame,
		)
		var buffer_state: Array = entity._rollback_buffer.get_at(frame)
		assert_eq(
			buffer_state[buffer_state.size() - 1],
			ReconcilableState.FrameAuthority.AUTHORITATIVE,
			"Buffer entry should be AUTHORITATIVE",
		)


class TestReplicationConfig:
	extends GutTest
	## Tests that _update_replication_config() registers the correct
	## properties based on _uses_split_packed_state().

	func before_each():
		ArrayPool.clear_all_pools()

	func after_each():
		ArrayPool.clear_all_pools()


	func test_non_split_registers_authoritative_packed_state():
		var root_node := Node.new()
		root_node.name = "Root"
		add_child_autofree(root_node)

		var entity := NonSplitEntity.new()
		entity.name = "TestEntity"
		entity.root_path = NodePath("..")
		root_node.add_child(entity)

		entity._ready()
		entity._update_replication_config()

		var has_authoritative := (
			entity.replication_config.has_property(
				"TestEntity:authoritative_packed_state"
			)
		)
		assert_true(
			has_authoritative,
			"Non-split entity should register "
			+ "authoritative_packed_state",
		)


	func test_non_split_does_not_register_predicted():
		var root_node := Node.new()
		root_node.name = "Root"
		add_child_autofree(root_node)

		var entity := NonSplitEntity.new()
		entity.name = "TestEntity"
		entity.root_path = NodePath("..")
		root_node.add_child(entity)

		entity._ready()
		entity._update_replication_config()

		var has_predicted := entity.replication_config.has_property(
			"TestEntity:predicted_packed_state"
		)
		assert_false(
			has_predicted,
			"Non-split entity should NOT register "
			+ "predicted_packed_state",
		)


	func test_split_registers_predicted_and_authoritative():
		var root_node := Node.new()
		root_node.name = "Root"
		add_child_autofree(root_node)

		var entity := SplitEntity.new()
		entity.name = "TestEntity"
		entity.root_path = NodePath("..")
		root_node.add_child(entity)

		entity._ready()
		entity._update_replication_config()

		var has_predicted := entity.replication_config.has_property(
			"TestEntity:predicted_packed_state"
		)
		var has_authoritative := entity.replication_config.has_property(
			"TestEntity:authoritative_packed_state"
		)
		assert_true(
			has_predicted,
			"Split entity should register "
			+ "predicted_packed_state",
		)
		assert_true(
			has_authoritative,
			"Split entity should register "
			+ "authoritative_packed_state",
		)
