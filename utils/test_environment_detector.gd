class_name TestEnvironmentDetector
extends RefCounted
## Detects whether the game is running in a test environment (GUT tests).
##
## This class provides static methods to check if the game is currently running
## under the GUT (Godot Unit Test) framework, which is useful for disabling
## certain checks or behaviors during testing.


# Cache for test environment detection - only cache positive results because
# GUT may not be in tree yet during early initialization.
static var _is_test_env_cached: Variant = null


## Returns true if running in a test environment (GUT).
##
## Uses multiple detection methods and caches positive results for performance.
## Only caches positive results because GUT may not be in tree yet during early
## initialization (autoloads run before GUT is added).
static func is_running_in_test_env(tree_owner: Node = null) -> bool:
	# Only cache positive results because GUT may not be in tree yet during
	# early initialization (autoloads run before GUT is added).
	if _is_test_env_cached == true:
		return true

	_calculate_is_running_in_test_env(tree_owner)
	return _is_test_env_cached == true


static func _calculate_is_running_in_test_env(tree_owner: Node = null) -> void:
	# Check multiple indicators that we're running in a test environment.
	# Method 1: Check if running with gut_cmdln.gd (command line tests).
	# The SceneTree script will be gut_cmdln.gd when running tests.
	var tree: SceneTree = null
	if tree_owner != null and tree_owner.is_inside_tree():
		tree = tree_owner.get_tree()

	if tree:
		var script = tree.get_script()
		if script:
			var script_path = script.resource_path
			if "gut_cmdln" in script_path or "gut_cli" in script_path:
				_is_test_env_cached = true
				return

	# Method 2: Check if GUT is in the scene tree.
	var root = tree.root if tree else null
	if root:
		for child in root.get_children():
			var child_class = child.get_class()
			# Check for GutMain or RunFromEditor (editor test runner).
			if (
				child_class == "GutMain"
				or child.has_method("get_test_count")
				or child.name == "RunFromEditor"
			):
				_is_test_env_cached = true
				return

	# Method 3: Check command-line arguments for GUT-specific flags or if
	# loading GUT scenes.
	for arg in OS.get_cmdline_args():
		if (
			(arg.begins_with("-g") and ("test" in arg or "dir" in arg or "exit" in arg))
			or "addons/gut" in arg
		):
			_is_test_env_cached = true
			return
