@tool
class_name FrameProcessor
extends Node
## Helper node that enables any node to participate in frame-synchronous
## network processing without full rollback support.
##
## FrameProcessor acts as a bridge between FrameDriver and game logic nodes
## that need to run during network frame simulation but don't extend
## ReconcilableState (i.e., they don't need server-mismatch detection and
## rollback).
##
## Typical use cases:
## - UI updates that sync with game state
## - Visual effects that don't affect gameplay
## - Audio triggers based on network events
## - Analytics/logging during frame processing
##
## Usage pattern:
## 1. Add FrameProcessor as a child of your networked node
## 2. Set root_path to point to the node that implements _network_process()
## 3. FrameDriver will automatically call root._network_process() during each
##    network frame
##
## Example scene tree:
## ```
## MyGameNode (has _network_process method)
##   ├── FrameProcessor (root_path = "..")
##   └── Sprite2D
## ```

## Path to the node that implements _network_process().
## Will be auto-populated to owner when first added in editor.
@export var root_path: NodePath:
	set(value):
		root_path = value
		update_configuration_warnings()

## Reference to the root node (cached for performance).
var root: Node:
	get:
		return get_node_or_null(root_path)


func _enter_tree() -> void:
	if Engine.is_editor_hint():
		return
	Netcode.frame_driver.add_network_frame_processor(self )


func _exit_tree() -> void:
	if Engine.is_editor_hint():
		return
	Netcode.frame_driver.remove_network_frame_processor(self )


func _ready() -> void:
	# Auto-populate root_path when first placed in a scene.
	if Engine.is_editor_hint() and root_path.is_empty():
		root_path = self.get_path_to(owner)
	update_configuration_warnings()


## Called by FrameDriver during network frame processing.
## Delegates to root node's _network_process() method.
func _network_process() -> void:
	if is_instance_valid(root) and root.has_method("_network_process"):
		root._network_process()


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := []

	if root_path.is_empty():
		warnings.append("root_path must be defined")
	elif not is_instance_valid(root):
		warnings.append("root_path does not point to a valid node")
	elif not root.has_method("_network_process"):
		warnings.append(
			"The node at root_path must have a _network_process() method"
		)

	return warnings
