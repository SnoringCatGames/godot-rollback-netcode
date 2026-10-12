extends SceneTree
## Loads every GDScript file the addon ships and exits 1 if one fails
## to compile, or if Godot logs any error while they load. run.sh runs
## this in the harness project, after importing it, as:
##
##   godot --headless --path <project> -s check_addon_scripts.gd \
##       -- --expected-scripts=<count>

const _ADDON_DIR := "res://addons/rollback_netcode"
## Not compiled here. examples/ is a separate project, which its
## .gdignore keeps out of consuming games. test/ extends GUT's
## GutTest, which the addon doesn't ship.
const _SKIPPED_DIRS: Array[String] = ["examples", "test"]
const _EXPECTED_SCRIPTS_ARG := "--expected-scripts="

var _error_log := _ErrorLog.new()


## Collects every error Godot logs: parse and compile errors, failed
## loads, and a failed autoload. Logger callbacks can run on any
## thread, hence the mutex.
class _ErrorLog:
	extends Logger

	var _mutex := Mutex.new()
	var _errors: Array[String] = []


	func _log_error(
		_function: String,
		file: String,
		line: int,
		code: String,
		rationale: String,
		_editor_notify: bool,
		error_type: int,
		_script_backtraces: Array[ScriptBacktrace],
	) -> void:
		if error_type == ERROR_TYPE_WARNING:
			return
		var message := rationale if not rationale.is_empty() else code
		_mutex.lock()
		_errors.append("%s:%d: %s" % [file, line, message])
		_mutex.unlock()


	func _log_message(_message: String, _is_error: bool) -> void:
		pass


	func get_errors() -> Array[String]:
		_mutex.lock()
		var errors := _errors.duplicate()
		_mutex.unlock()
		return errors


func _init() -> void:
	# Registered before the autoloads load, so a Netcode autoload that
	# fails to compile is counted too.
	OS.add_logger(_error_log)


func _initialize() -> void:
	var paths := _find_scripts(_ADDON_DIR)
	var failed: Array[String] = []
	for path in paths:
		var script := load(path) as Script
		if (
			script == null
			or not (script.can_instantiate() or script.is_abstract())
		):
			failed.append(path)
	OS.remove_logger(_error_log)
	var errors := _error_log.get_errors()

	for path in failed:
		printerr("parse-check: failed to compile %s" % path)
	for error in errors:
		printerr("parse-check: logged error: %s" % error)
	# run.sh counts the scripts in the repo itself, so a copy that lost
	# files, or a walk here that missed some, fails too.
	var expected := _get_expected_script_count()
	var is_count_ok := paths.size() == expected
	if not is_count_ok:
		printerr(
			"parse-check: found %d scripts under %s, run.sh counted %d"
			% [paths.size(), _ADDON_DIR, expected]
		)
	if failed.is_empty() and errors.is_empty() and is_count_ok:
		print("parse-check: OK, compiled %d scripts" % paths.size())
		quit(0)
	else:
		printerr(
			"parse-check: FAILED, %d of %d scripts failed to compile,"
			% [failed.size(), paths.size()]
			+ " %d errors logged" % errors.size()
		)
		quit(1)


func _find_scripts(dir_path: String) -> Array[String]:
	var paths: Array[String] = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		printerr("parse-check: can't open %s" % dir_path)
		return paths
	for file in dir.get_files():
		if file.get_extension() == "gd":
			paths.append(dir_path.path_join(file))
	for subdir in dir.get_directories():
		if dir_path == _ADDON_DIR and subdir in _SKIPPED_DIRS:
			continue
		paths.append_array(_find_scripts(dir_path.path_join(subdir)))
	return paths


## Returns -1 when the argument is missing, which fails the count.
func _get_expected_script_count() -> int:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(_EXPECTED_SCRIPTS_ARG):
			return int(arg.trim_prefix(_EXPECTED_SCRIPTS_ARG))
	return -1
