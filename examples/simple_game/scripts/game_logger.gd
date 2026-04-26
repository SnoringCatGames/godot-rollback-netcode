class_name GameLogger
extends NetworkLogger
## Example NetworkLogger implementation using print_rich with color-coded
## output.
##
## Format: "[LEVEL][category] message"


func verbose(message: String, category: StringName = CATEGORY_DEFAULT) -> void:
	print_rich("[color=gray][VERBOSE][%s] %s[/color]" % [category, message])


func info(message: String, category: StringName = CATEGORY_DEFAULT) -> void:
	print_rich("[color=cyan][INFO][%s] %s[/color]" % [category, message])


func warning(message: String, category: StringName = CATEGORY_DEFAULT) -> void:
	print_rich("[color=yellow][WARNING][%s] %s[/color]" % [category, message])


func error(message: String, category: StringName = CATEGORY_DEFAULT) -> void:
	print_rich("[color=red][ERROR][%s] %s[/color]" % [category, message])


func fatal(message: String, category: StringName = CATEGORY_DEFAULT) -> void:
	print_rich("[color=magenta][FATAL][%s] %s[/color]" % [category, message])
	assert(false, message)
