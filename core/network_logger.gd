class_name NetworkLogger
extends Node
## Abstract logging interface for rollback netcode plugin.
##
## Provides a unified logging API that users implement to integrate with their
## game's logging system (console, file, UI, etc.). Uses String-based
## categories for extensibility.
##
## Usage:
## ```gdscript
## class_name MyGameLogger
## extends NetworkLogger
##
## func verbose(message: String, category: StringName = CATEGORY_DEFAULT) -> void:
##     print("[VERBOSE][%s] %s" % [category, message])
##
## func info(message: String, category: StringName = CATEGORY_DEFAULT) -> void:
##     print("[INFO][%s] %s" % [category, message])
##
## func warning(message: String, category: StringName = CATEGORY_DEFAULT) -> void:
##     push_warning("[%s] %s" % [category, message])
##
## func error(message: String, category: StringName = CATEGORY_DEFAULT) -> void:
##     push_error("[%s] %s" % [category, message])
##     print_stack()
##
## func fatal(message: String, category: StringName = CATEGORY_DEFAULT) -> void:
##     push_error("[FATAL][%s] %s" % [category, message])
##     print_stack()
##     assert(false, message)
## ```


# Predefined log categories (users can pass custom strings for extensibility).
const CATEGORY_SYSTEM_INITIALIZATION := &"SysInit"
const CATEGORY_DEFAULT := &"default"
const CATEGORY_NETWORK_SYNC := &"network_sync"
const CATEGORY_CONNECTIONS := &"connections"
const CATEGORY_CORE_SYSTEMS := &"core_systems"
const CATEGORY_GAME_STATE := &"game_state"
const CATEGORY_PLAYER_ACTIONS := &"PlayerActions"
const CATEGORY_USER_INTERACTION := &"PlayerInteraction"


## Whether verbose/debug logs should be output.
## When false, verbose() calls should be guarded with if checks to avoid
## string manipulation overhead.
var is_verbose: bool:
	get:
		return (
			Netcode.settings.includes_verbose_logs if
			is_instance_valid(Netcode)
				and is_instance_valid(Netcode.settings)
			else true
		)


## Log a verbose/debug message.
## Used for detailed debugging information during development.
##
## @param message: The message to log.
## @param category: Log category string (use predefined constants or custom).
func verbose(message: String, category: StringName = CATEGORY_DEFAULT) -> void:
	if not is_verbose:
		return
	# Default implementation: print to console.
	print("[VERBOSE][%s] %s" % [category, message])


## Log an informational message.
## Used for general operational messages.
##
## @param message: The message to log.
## @param category: Log category string.
func print(message: String, category: StringName = CATEGORY_DEFAULT) -> void:
	# Default implementation: print to console.
	print("[INFO][%s] %s" % [category, message])


## Log a warning message.
## Used for non-fatal issues that should be noted.
##
## @param message: The message to log.
## @param category: Log category string.
func warning(message: String, category: StringName = CATEGORY_DEFAULT) -> void:
	# Default implementation: print warning to console.
	push_warning("[%s] %s" % [category, message])


## Log an error message.
## Used for recoverable error conditions.
##
## @param message: The message to log.
## @param category: Log category string.
func error(message := "", category: StringName = CATEGORY_DEFAULT) -> void:
	# Default implementation: print error to console with stack trace.
	push_error("[%s] %s" % [category, message])
	print_stack()


## Log a fatal error message and halt execution.
## Used for critical invariants that must never be violated.
##
## @param message: The message to log.
## @param category: Log category string.
func fatal(message := "", category: StringName = CATEGORY_DEFAULT) -> void:
	# Default implementation: print fatal error with stack trace and assert.
	push_error("[FATAL][%s] %s" % [category, message])
	print_stack()
	assert(false, message)


## Check a condition and log an error if false.
## Returns the condition value for inline usage.
##
## @param condition: Condition to check.
## @param message: Error message if condition is false.
## @return: The condition value (pass-through).
func check(condition: bool, message := "") -> bool:
	if not condition:
		error(message, CATEGORY_DEFAULT)
	return condition


## Ensure a condition is true, logging a fatal error and asserting if false.
## Use for critical invariants that must never be violated.
##
## @param condition: Condition that must be true.
## @param message: Fatal error message if condition is false.
## @return: The condition value (pass-through).
func ensure(condition: bool, message := "") -> bool:
	if not condition:
		fatal(message, CATEGORY_DEFAULT)
	return condition
