class_name MatchState
extends RefCounted
## Abstract base class for managing match state across network sessions.
##
## Provides generic player roster management and match timing infrastructure.
## Games extend this class to add game-specific state (kills, scores, etc.)
## and logic.
##
## Example:
## ```gdscript
## class_name MyGameMatchState
## extends MatchState
##
## signal player_scored(player_id: int, points: int)
##
## var scores := {}  # Dictionary<int, int>
##
## func add_score(player_id: int, points: int) -> void:
##     scores[player_id] = scores.get(player_id, 0) + points
##     player_scored.emit(player_id, points)
## ```

# --- Generic Signals ---

## Emitted when a player joins the match.
signal player_joined(player: PlayerState)

## Emitted when a player leaves the match.
signal player_left(player: PlayerState)

## Emitted when player roster changes.
signal players_updated

## Emitted when match ends.
signal match_ended

## Reference to synchronizer (set by MatchStateSynchronizer).
var synchronizer = null

# --- Player Roster (Generic) ---

## Active players indexed by player_id.
## Dictionary<int, PlayerState>
var players_by_id: Dictionary = {}

# --- Match Timing (Generic) ---

## Server frame index when match started (-1 if not started).
var match_start_frame_index := -1

## Match duration in microseconds (0 if unlimited).
var match_duration_usec := 0

## True if match has ended.
var is_match_ended := false

## Time remaining in seconds (computed property).
## Accounts for match-start countdown - time only starts counting down after
## the countdown ends.
var match_time_remaining_sec: float:
	get:
		if match_start_frame_index < 0:
			return 0.0
		# Account for match-start countdown - gameplay starts after it ends.
		var countdown_end := (
			Netcode.frame_driver
				.match_start_countdown_end_frame_index
		)
		var effective_start := (
			countdown_end if countdown_end > 0
			else match_start_frame_index
		)
		var elapsed_frames := (
			Netcode.server_frame_index
			- effective_start
		)
		var elapsed_sec := (
			elapsed_frames
			/ Netcode.frame_driver.target_network_fps
		)
		var remaining_sec := (
			(match_duration_usec / 1_000_000.0)
			- elapsed_sec
		)
		return max(0.0, remaining_sec)

## True if match timer has started.
var is_match_active: bool:
	get:
		return match_start_frame_index >= 0

## True if match time has expired.
var is_match_time_expired: bool:
	get:
		return (
			match_start_frame_index >= 0
			and match_duration_usec > 0
			and match_time_remaining_sec <= 0.0
		)

# --- Packed Player State (Generic) ---

## Packed array of player states for network replication.
## - The Array is continuously updated on the server.
## - The Array is synced to clients via MultiplayerSynchronizer.
## - The Dictionary is then derived from the Array, and is used for more
##   efficient local look-ups.
var packed_players := []:
	set(value):
		if Netcode.log.is_verbose:
			Netcode.log.verbose(
				("MatchState.packed_players changed"
				+ " (size=%d)") % value.size(),
				NetworkLogger.CATEGORY_GAME_STATE,
			)
		packed_players = value
		# Trigger virtual method for subclass customization.
		_on_packed_players_changed()


# --- Public API ---


## Add a player to the match.
func server_add_player(player: PlayerState) -> void:
	players_by_id[player.player_id] = player
	_server_pack_players()
	player_joined.emit(player)
	players_updated.emit()


## Remove a player from the match.
func server_remove_player(player_id: int) -> void:
	var player: PlayerState = players_by_id.get(player_id)
	if player == null:
		return

	players_by_id.erase(player_id)
	_server_pack_players()
	player_left.emit(player)
	players_updated.emit()


## Get player by ID (returns null if not found).
func get_player(player_id: int) -> PlayerState:
	return players_by_id.get(player_id)


## Get all players for a given peer_id.
func get_players_for_peer(peer_id: int) -> Array[PlayerState]:
	var result: Array[PlayerState] = []
	for player_id in players_by_id:
		var player: PlayerState = players_by_id[player_id]
		if player.peer_id == peer_id:
			result.append(player)
	return result


## Start the match at the current frame.
func server_start_match(duration_sec: float) -> void:
	match_start_frame_index = Netcode.server_frame_index
	match_duration_usec = int(duration_sec * 1_000_000)
	is_match_ended = false

	if Netcode.log.is_verbose:
		Netcode.log.verbose(
			"Match started at frame %d, duration %.1f sec" % [
				match_start_frame_index,
				duration_sec
			],
			NetworkLogger.CATEGORY_GAME_STATE
		)


## End the match.
func server_end_match() -> void:
	is_match_ended = true
	match_ended.emit()

	if Netcode.log.is_verbose:
		Netcode.log.verbose(
			"Match ended at frame %d" % Netcode.server_frame_index,
			NetworkLogger.CATEGORY_GAME_STATE
		)


## Get player count.
func get_player_count() -> int:
	return players_by_id.size()


# --- Internal Methods ---


## Factory method for creating player state instances.
## Override in subclasses to return game-specific player state.
func _create_player_state() -> PlayerState:
	return PlayerState.new()


## Pack player states for network replication (called on server).
func _server_pack_players() -> void:
	if Netcode.log.is_verbose:
		Netcode.log.verbose(
			("MatchState._server_pack_players:"
			+ " packing %d players")
			% players_by_id.size(),
			NetworkLogger.CATEGORY_GAME_STATE,
		)

	var new_packed_players := []
	new_packed_players.resize(players_by_id.size())
	var i := 0
	for player_id in players_by_id:
		new_packed_players[i] = players_by_id[player_id].get_packed_state()
		i += 1

	# Avoid triggering setter if unchanged (performance).
	if synchronizer != null:
		synchronizer._is_packing_state_locally = true
	packed_players = new_packed_players
	if synchronizer != null:
		synchronizer._is_packing_state_locally = false

	# Emit players_updated on server side (clients get it via replication
	# setter).
	players_updated.emit()


## Unpack player states from network replication (called on client).
func _client_unpack_players() -> void:
	if Netcode.log.is_verbose:
		Netcode.log.verbose(
			("MatchState._client_unpack_players:"
			+ " unpacking %d players")
			% packed_players.size(),
			NetworkLogger.CATEGORY_GAME_STATE,
		)

	# Clear existing players.
	players_by_id.clear()

	# Unpack each player.
	for packed_player in packed_players:
		var player := _create_player_state()
		player.populate_from_packed_state(packed_player)
		players_by_id[player.player_id] = player

	players_updated.emit()


## Virtual method called when packed_players changes.
## Override in subclasses to add custom unpacking logic.
## NOTE: This is called during server packing too, so check if you need to
## guard with a flag to avoid redundant work.
func _on_packed_players_changed() -> void:
	# Default: do nothing (subclasses can override).
	pass
