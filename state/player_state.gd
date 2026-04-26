class_name PlayerState
extends RefCounted
## Base class for player match state.
##
## Contains core networking properties. Games extend this class to add
## game-specific player attributes (names, colors, scores, etc.).
##
## - This should contain state that doesn't need to sync very often (every few
##   seconds at the most).
## - State that needs to sync every frame should instead be tracked in
##   CharacterStateFromServer (or a subclass of it).


const _PROPERTY_NAMES := [
	"player_id",
	"peer_id",
	"local_player_index",
	"connect_frame_index",
	"disconnect_frame_index",
]

var player_id: int = 0
var peer_id: int = 0
var local_player_index: int = 0

var connect_frame_index := 0
var disconnect_frame_index := 0

var is_connected_to_server: bool:
	get:
		return connect_frame_index >= disconnect_frame_index


func get_packed_state() -> Array:
	var packed_state := []
	packed_state.resize(_PROPERTY_NAMES.size())
	var i := 0
	for property_name in _PROPERTY_NAMES:
		packed_state[i] = get(property_name)
		i += 1
	return packed_state


func populate_from_packed_state(packed_state: Array) -> void:
	var i := 0
	for property_name in _PROPERTY_NAMES:
		set(property_name, packed_state[i])
		i += 1


static func get_player_id_from_packed_state(packed_state: Array) -> int:
	return packed_state[0]


func _get_base_property_names() -> Array:
	return _PROPERTY_NAMES


func set_up(
		p_player_id: int,
		p_peer_id: int,
		p_local_index: int,
		_p_attributes: Dictionary) -> void:
	player_id = p_player_id
	peer_id = p_peer_id
	local_player_index = p_local_index


func get_string() -> String:
	return "Player %d [peer:%d, local:%d]" % [
		player_id,
		peer_id,
		local_player_index
	]
