class_name ClientSession
extends RefCounted

var is_game_active := false
var is_game_loading := false

## Latest match state (set via copy_latest_state).
## Note: Subclass of MatchState determined by game.
var latest_match_state: MatchState = null
var latest_local_device_configs: Array[DeviceConfig] = []
var latest_local_player_ids: Array[int] = []
var latest_local_player_attributes: Array[Dictionary] = []

## Number of local players on this client.
var local_player_count: int:
	get:
		return local_device_configs.size()

## Device configurations for each local player.
## Array index corresponds to local_player_index.
var local_device_configs: Array[DeviceConfig] = []

## GameLift player session IDs from backend matchmaking.
## Array index corresponds to local_player_index.
var client_session_ids: Array[String] = []

var local_player_ids: Array[int] = []

## Client-generated player attributes to send to server during connection.
## Array index corresponds to local_player_index.
var local_player_attributes: Array[Dictionary] = []

## Level preferences for matchmaking (optional).
var level_preferences: LevelPreferences = null

## Selected level ID from matchmaking response.
var selected_level_id: StringName = ""

## Message from server (e.g., shutdown notification) to display on game over
## screen.
var latest_server_message := ""

## Backend player ID mapping received from server
## before match end. Maps game player_id (int) to
## backend player_id (String).
var backend_player_id_map: Dictionary = {}

## Profile image URL mapping received from server.
## Maps game player_id (int) to URL (String).
var profile_image_urls: Dictionary = {}

## Auth display name mapping received from server.
## Maps game player_id (int) to display name
## (String). Empty for anonymous players.
var auth_display_names: Dictionary = {}

## Recent match participants for post-match friend
## add. Each entry: {"player_id": int,
## "display_name": String,
## "backend_player_id": String}.
var latest_match_participants: Array[Dictionary] = []


func _init() -> void:
	clear()


## Validates that session IDs are properly populated.
## Returns true if client_session_ids array matches player count and contains no empty
## strings.
func has_valid_client_session_ids() -> bool:
	if client_session_ids.size() != local_device_configs.size():
		return false
	for session_id in client_session_ids:
		if session_id.is_empty():
			return false
	return true


func clear() -> void:
	is_game_active = false
	is_game_loading = false
	client_session_ids.clear()
	local_device_configs.clear()
	local_player_ids.clear()
	local_player_attributes.clear()
	level_preferences = null
	selected_level_id = ""


func clear_latest_state() -> void:
	if latest_match_state != null and latest_match_state.has_method("clear"):
		latest_match_state.clear()
	latest_local_device_configs.clear()
	latest_local_player_ids.clear()
	latest_local_player_attributes.clear()
	latest_server_message = ""
	backend_player_id_map.clear()
	profile_image_urls.clear()
	auth_display_names.clear()
	latest_match_participants.clear()


## Copy current state into latest_* properties.
## Consumers should call this with their current match_state.
## Note: match_state must have a duplicate() method.
func copy_latest_state(match_state: MatchState) -> void:
	if match_state.has_method("duplicate"):
		latest_match_state = match_state.duplicate()
	else:
		latest_match_state = match_state
	latest_local_device_configs = local_device_configs.duplicate()
	latest_local_player_ids = local_player_ids.duplicate()
	latest_local_player_attributes = local_player_attributes.duplicate()
