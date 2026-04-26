## Utility class for parsing and comparing semantic version strings.
## Format: "major.minor.patch" (e.g., "1.2.3").
class_name SemanticVersion
extends RefCounted


## Parse semantic version string into dictionary with major, minor, patch keys.
## Returns empty dictionary if version string is invalid.
##
## Example:
##   parse("1.2.3") -> {major: 1, minor: 2, patch: 3}
##   parse("invalid") -> {}
static func parse(version: String) -> Dictionary:
	var regex := RegEx.new()
	regex.compile("^(\\d+)\\.(\\d+)\\.(\\d+)$")
	var result := regex.search(version)
	if result:
		return {
			"major": int(result.get_string(1)),
			"minor": int(result.get_string(2)),
			"patch": int(result.get_string(3))
		}
	return {}


## Compare two version strings for exact match.
## Returns true if both versions are valid and all components match.
##
## Example:
##   compare("1.2.3", "1.2.3") -> true
##   compare("1.2.3", "1.2.4") -> false
##   compare("invalid", "1.2.3") -> false
static func compare(v1: String, v2: String) -> bool:
	var parsed1 := parse(v1)
	var parsed2 := parse(v2)
	if parsed1.is_empty() or parsed2.is_empty():
		return false
	return (
		parsed1.major == parsed2.major
		and parsed1.minor == parsed2.minor
		and parsed1.patch == parsed2.patch
	)


## Validate version string format.
## Returns true if the version string is a valid semantic version.
##
## Example:
##   is_valid("1.2.3") -> true
##   is_valid("1.x.3") -> false
static func is_valid(version: String) -> bool:
	return not parse(version).is_empty()
