@tool
class_name TestNetworkedEntity
extends ReconcilableState
## A simple test entity for networked state and rollback tests.
##
## This entity tracks position and velocity, which can be used to
## test rollback reconciliation logic. It mirrors the helper of
## the same name in the consuming game's test suite, which
## test_frame_driver.gd was written against; the addon ships its
## own copy so its tests run without a host project (RN3).


var position := Vector2.ZERO
var velocity := Vector2.ZERO
var custom_data: int = 0

@warning_ignore("unused_private_class_variable")
var _synced_properties_and_rollback_diff_thresholds := {
	"position": 1.0,
	"velocity": 0.5,
	"custom_data": 0,
}

## Whether this entity has been reconciled.
var was_reconciled := false

## Number of times _network_process was called.
var network_process_count := 0

## Last frame index processed.
var last_processed_frame := -1


func _init() -> void:
	super._init()
	# Initialize replication config for programmatic instantiation.
	if replication_config == null:
		replication_config = SceneReplicationConfig.new()


func _has_non_rollbackable_interactions() -> bool:
	return false # Test class doesn't use interaction tracking.


func _get_is_server_authoritative() -> bool:
	return true


func _pre_network_process() -> void:
	# In a real implementation, this would sync state from the
	# rollback buffer.
	pass


func _network_process() -> void:
	network_process_count += 1
	last_processed_frame = frame_index

	# Simple physics: position += velocity * delta.
	position += velocity * (
		Netcode.frame_driver.target_network_time_step_sec)


func _post_network_process() -> void:
	# In a real implementation, this would call the base class
	# to pack state for replication. For this test helper, we
	# keep it simple.
	pass


## Implement required abstract methods from ReconcilableState.
func _get_default_values() -> Array:
	return [Vector2.ZERO, Vector2.ZERO, 0]


func _sync_to_scene_state(_previous_state: Array) -> void:
	# For test purposes, state is stored directly in member
	# variables.
	pass


func _sync_from_scene_state() -> void:
	# For test purposes, state is stored directly in member
	# variables.
	pass


## Helper method to detect state mismatches for testing.
func has_state_mismatch(
	client_state: Array,
	server_state: Array
) -> bool:
	if client_state.size() < 5 or server_state.size() < 5:
		return false

	# Check position mismatch (x, y).
	var pos_diff := Vector2(
		abs(client_state[0] - server_state[0]),
		abs(client_state[1] - server_state[1])
	)
	if pos_diff.length() > 1.0:
		return true

	# Check velocity mismatch.
	var vel_diff := Vector2(
		abs(client_state[2] - server_state[2]),
		abs(client_state[3] - server_state[3])
	)
	if vel_diff.length() > 0.5:
		return true

	# Check custom data mismatch.
	if client_state[4] != server_state[4]:
		return true

	return false


## Reset test state.
func reset_test_state() -> void:
	was_reconciled = false
	network_process_count = 0
	last_processed_frame = -1


## Create a simple test entity with given initial values.
static func create_test_entity(
	initial_position := Vector2.ZERO,
	initial_velocity := Vector2.ZERO
) -> TestNetworkedEntity:
	var entity := TestNetworkedEntity.new()
	entity.position = initial_position
	entity.velocity = initial_velocity
	# Initialize rollback buffer for testing
	entity._set_up_rollback_buffer()
	entity._parse_property_names()
	return entity
