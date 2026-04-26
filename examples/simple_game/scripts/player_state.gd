@tool
class_name PlayerState
extends ReconcilableState
## Server-authoritative player state for simple_game example.
##
## Synchronizes position and velocity across the network with rollback
## reconciliation. Server is the authority for all player state.


# Synced properties.
var position := Vector2.ZERO
var velocity := Vector2.ZERO

# Define synced properties and rollback thresholds.
var _synced_properties_and_rollback_diff_thresholds := {
	"position": 1.0,  # 1 pixel threshold.
	"velocity": 10.0,  # 10 pixels/sec threshold.
}


func _get_is_server_authoritative() -> bool:
	return true


func _has_non_rollbackable_interactions() -> bool:
	return false


func _is_interaction_rollbackable(_interaction_type: int) -> bool:
	return true


func _get_default_values() -> Array:
	return [Vector2.ZERO, Vector2.ZERO]


func _sync_to_scene_state(_previous_state: Array) -> void:
	if is_instance_valid(root):
		root.position = position


func _restore_indirect_interaction_state(_frame_state: Array) -> void:
	pass  # No indirect interaction state in this simple example.


func _sync_from_scene_state() -> void:
	if is_instance_valid(root):
		position = root.position
		velocity = root.velocity
