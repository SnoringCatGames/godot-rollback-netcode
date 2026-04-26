class_name ProcessSentinel
extends Node
## Provides signals that fire at the very beginning and end of each frame.
##
## Creates helper nodes directly under the scene tree root with extreme
## process_priority values to ensure deterministic frame ordering:
## - PreProcessSentinel: MIN_INT priority (runs first)
## - PostProcessSentinel: MAX_INT priority (runs last)
##
## This is important for frame-synchronous networking where execution order
## must be deterministic.

signal pre_physics_process(delta: float)
signal post_physics_process(delta: float)
signal pre_process(delta: float)
signal post_process(delta: float)

const MIN_INT := -2147483648 # -(2^31)
const MAX_INT := 2147483647 # (2^31 - 1)

var _pre_process_sentinel: _ProcessSentinelHelper
var _post_process_sentinel: _ProcessSentinelHelper


func _ready() -> void:
	var root := get_tree().root

	# Godot traverses the scene tree in pre-order traversal, so we place both
	# sentinel helpers at the top layer, with one as the first child and one as
	# the last.

	_pre_process_sentinel = _ProcessSentinelHelper.new()
	_pre_process_sentinel.name = "PreProcessSentinel"
	_pre_process_sentinel.process_mode = Node.PROCESS_MODE_ALWAYS
	_pre_process_sentinel.process_priority = MIN_INT
	_pre_process_sentinel.physics_processed.connect(_pre_physics_process)
	_pre_process_sentinel.processed.connect(_pre_process)
	root.add_child.call_deferred(_pre_process_sentinel)
	root.move_child.call_deferred(_pre_process_sentinel, 0)

	_post_process_sentinel = _ProcessSentinelHelper.new()
	_post_process_sentinel.name = "PostProcessSentinel"
	_post_process_sentinel.process_mode = Node.PROCESS_MODE_ALWAYS
	_post_process_sentinel.process_priority = MAX_INT
	_post_process_sentinel.physics_processed.connect(_post_physics_process)
	_post_process_sentinel.processed.connect(_post_process)
	root.add_child.call_deferred(_post_process_sentinel)


func _pre_physics_process(delta: float) -> void:
	pre_physics_process.emit(delta)


func _post_physics_process(delta: float) -> void:
	post_physics_process.emit(delta)


func _pre_process(delta: float) -> void:
	pre_process.emit(delta)


func _post_process(delta: float) -> void:
	post_process.emit(delta)


class _ProcessSentinelHelper:
	extends Node
	signal physics_processed(delta: float)
	signal processed(delta: float)


	func _physics_process(delta: float) -> void:
		physics_processed.emit(delta)


	func _process(delta: float) -> void:
		processed.emit(delta)
