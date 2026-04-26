@tool
class_name ReconcilableState
extends MultiplayerSynchronizer
## Base class for all networked entities that require client-side prediction
## with server-mismatch reconciliation and rollback support.
##
## ReconcilableState is the foundation of the networking system,
## providing automatic state replication, client prediction, mismatch detection,
## and rollback reconciliation for any game entity. Subclasses define which
## properties to sync and how to integrate with the scene hierarchy.
##
## Architecture:
## This class bridges three systems:
## 1. **Godot MultiplayerSynchronizer**: Handles low-level replication of
##	  predicted_packed_state / authoritative_packed_state across network
## 2. **RollbackBuffer**: Stores historical states for time-travel during
##	  rollback
## 3. **NetworkFrameDriver**: Coordinates frame-synchronous simulation and
##	  rollback
##
## Server-authoritative vs client-authoritative:
## - **Server-authoritative** (default): Server is source of truth for entity
##   state (position, health, etc.)
## - **Client-authoritative**: Client is source of truth (used for player input)
##
## Typically used as a pair: one client-authoritative node for input, one
## server-authoritative node for all other state.
##
## Frame processing cycle (called by NetworkFrameDriver):
## 1. **_pre_network_process()**: Restore state from rollback buffer (frame N-1)
##	  and sync to scene
## 2. **_network_process()**: Game logic executes (implemented by subclass)
## 3. **_post_network_process()**: Pack state from scene back to properties and
##	  buffer
##
## Subclass requirements:
## - Define `_synced_properties_and_rollback_diff_thresholds` dictionary mapping
##   property names to mismatch thresholds
## - Implement `_get_default_values()` to return initial state
## - Implement `_sync_to_scene_state(previous_state)` to update scene from
##   networked properties
## - Implement `_sync_from_scene_state()` to update networked properties from
##   scene
## - Must be marked with @tool annotation
##
## Rollback reconciliation:
## When the server's authoritative state differs from client prediction beyond
## the configured threshold, a rollback is triggered:
## 1. State is restored to the mismatched frame
## 2. All frames from mismatch to present are re-simulated
## 3. Visual state smoothly interpolates (future: rollback visual interpolation)
##
## Thresholds (in _synced_properties_and_rollback_diff_thresholds):
## - Position: typically 1.0 pixel
## - Velocity: typically 10.0 pixels/sec
## - Boolean/String: exact match required (threshold N/A)
## - Numeric: absolute difference threshold
## - Vector2: distance_squared threshold
##
## Usage example:
## ```gdscript
## @tool
## class_name CharacterStateFromServer
## extends ReconcilableState
##
## var position := Vector2.ZERO
## var velocity := Vector2.ZERO
##
## var _synced_properties_and_rollback_diff_thresholds := {
##	   "position": 1.0,
##	   "velocity": 10.0,
## }
##
## func _get_default_values() -> Array:
##  	 return [Vector2.ZERO, Vector2.ZERO]
##
## func _sync_to_scene_state(_previous_state: Array) -> void:
##	   root.position = position
##	   root.velocity = velocity
##
## func _sync_from_scene_state() -> void:
##	   position = root.position
##	   velocity = root.velocity
## ```

enum FrameAuthority {
	UNKNOWN,
	AUTHORITATIVE,
	SERVER_PREDICTED,
	CLIENT_PREDICTED,
}

## Identifies the role of a ReconcilableState subclass
## within the 3-node player architecture. Used for
## sibling detection without compile-time class_name
## references to subclasses, which would create circular
## dependencies in exported builds.
enum ReconcilableStateType {
	GENERIC,
	CHARACTER_STATE,
	INPUT_FROM_CLIENT,
	FORWARDED_INPUT,
}

signal received_network_state(state_frame_index: int)
signal network_processed
signal player_id_changed(new_player_id: int)

const DEFAULT_POSITION_DIFF_ROLLBACK_THRESHOLD := 2.0
const DEFAULT_VELOCITY_DIFF_ROLLBACK_THRESHOLD := 20.0

# 0 should be NONE in all interaction enums.
const _NONE_INTERACTION_TYPE := 0

## Property type IDs for raw byte packing in
## StateBundler. Determined once from default values.
enum PackType {
	INT,
	FLOAT,
	VECTOR2,
}

# Debug buffer indices for per-frame debug metrics (preview mode only).
const _DEBUG_ROLLBACK_INDEX := 0
const _DEBUG_FAST_FORWARD_INDEX := 1
const _DEBUG_AUTHORITATIVE_STATE_DELAY_INDEX := 2
const _DEBUG_DEFAULT_ENTRY := [0, 0, -1]

## The estimated server frame, when this state occurred.
var frame_index := Utils.MIN_INT

## Unified interaction system properties.
## Interaction type is an integer enum value (child classes define specific enums).
var _last_interaction_type_internal := _NONE_INTERACTION_TYPE
var last_interaction_type: int:
	set(value):
		if (Netcode.log.is_verbose
				and Netcode.is_server
				and _last_interaction_type_internal != value):
			Netcode.log.verbose(
				"[INTERACTION] Player %d: %s (%d) -> %s (%d) at F:%d" % [
					player_id,
					_get_interaction_type_name(_last_interaction_type_internal),
					_last_interaction_type_internal,
					_get_interaction_type_name(value),
					value,
					Netcode.server_frame_index
				],
				NetworkLogger.CATEGORY_NETWORK_SYNC,
			)
		_last_interaction_type_internal = value
	get:
		return _last_interaction_type_internal

var last_interaction_frame_index := -1
var last_interaction_position := Vector2.ZERO
var last_interaction_velocity := Vector2.ZERO

@warning_ignore("unused_private_class_variable")
var _last_reconciled_interaction_frame_index := -1

## This identifies whether this data originated from an authoritative source.
var frame_authority := FrameAuthority.UNKNOWN

## If true, the server is the authoritative source of data for this state.
##
## This likely should only be false for input from the client.
var is_server_authoritative: bool:
	get:
		return _get_is_server_authoritative()

var is_client_authoritative: bool:
	get:
		return not _get_is_server_authoritative()

var _is_packing_state_locally := false

## Pending outgoing states for StateBundler. When
## bundling is active, _assign_outgoing_state stores
## the latest state per channel (predicted and
## authoritative) instead of setting the synchronizer
## properties. Only the latest per channel is kept to
## minimize bundle size and deserialization overhead.
var _pending_bundle_predicted: Array = []
var _pending_bundle_authoritative: Array = []

## Additional replication channel for predicted state (current frame,
## SERVER_PREDICTED). Only used by nodes that override
## _uses_split_packed_state() to send predicted state alongside
## authoritative confirmations each tick.
var predicted_packed_state := []:
	set(value):
		predicted_packed_state = value
		if not _is_packing_state_locally:
			if _should_use_network_simulator():
				Netcode.condition_simulator.queue_incoming_state(
					self , value,
					NetworkConditionSimulator.CHANNEL_PREDICTED)
			else:
				_handle_new_state_from_network(value)

## Primary replication channel for packed state. All nodes replicate through
## this property. Contains properties + frame_authority + frame_index.
## For non-split nodes this is the only channel; for split nodes this
## carries confirmed authoritative state (past frame).
var authoritative_packed_state := []:
	set(value):
		authoritative_packed_state = value
		if not _is_packing_state_locally:
			if _should_use_network_simulator():
				Netcode.condition_simulator.queue_incoming_state(
					self , value,
					NetworkConditionSimulator.CHANNEL_AUTHORITATIVE)
			else:
				_handle_new_state_from_network(value)

## Tracks whether we've received valid initial state from the server.
## Used to allow the first state through even if it's "too old" (spawn data).
var _has_received_valid_state := false

var _property_names_for_packing: Array[StringName] = []
# Dictionary<StringName, int>
var _property_name_to_pack_index := {}

## Cached property type layout for raw byte packing.
## One PackType per synced property, determined from
## _get_default_values() during _parse_property_names().
## Used by StateBundler for encode/decode without
## var_to_bytes overhead.
var _pack_types: Array[int] = []

## Raw byte size of one packed state (all properties
## + frame_authority + frame_index). Cached for fast
## decode offset calculation.
var _pack_byte_size := 0

## Server-assigned player ID (integer).
##
## - This uniquely identifies a player across the entire game session.
## - Assigned by the server when spawning new networked nodes.
## - Local-only lobby players use negative IDs (-1, -2, -3, etc.).
var player_id: int = 0:
	set(value):
		if value != player_id:
			player_id = value

			# Only update authority if we have a valid peer mapping.
			# For remote players on clients, this mapping won't exist yet
			# during initial replication - it will be set later in
			# _on_player_joined(), which will call update_authority()
			# explicitly.
			if Netcode.get_peer_id_from_player_id(value) != 0:
				update_authority()

			# Assign player_id on sibling nodes.
			if is_server_authoritative:
				if is_instance_valid(input_from_client):
					input_from_client.player_id = player_id
				if is_instance_valid(forwarded_input_from_server):
					forwarded_input_from_server.player_id = player_id

			player_id_changed.emit(player_id)

## Peer ID that owns this entity.
var peer_id: int:
	get:
		return Netcode.get_peer_id_from_player_id(player_id)

## Local player index within the peer (0, 1, 2...).
var local_player_index: int:
	get:
		return Netcode.get_local_player_index_from_player_id(player_id)

var authority_id: int:
	get:
		if is_server_authoritative:
			return NetworkConnector.SERVER_ID
		return peer_id

## Sibling nodes in the 3-node architecture for players:
## - state_from_server: CharacterStateFromServer (server-authoritative physics/position)
## - input_from_client: PlayerInputFromClient (client-authoritative local input)
## - forwarded_input_from_server: ForwardedPlayerInputFromServer (server-authoritative remote input)
##
## For NPCs, only state_from_server is present.
## For 2-node players (legacy), only state_from_server and input_from_client are present.
var state_from_server: ReconcilableState:
	set(value):
		state_from_server = value
		_get_configuration_warnings()
var input_from_client: ReconcilableState:
	set(value):
		input_from_client = value
		_get_configuration_warnings()
var forwarded_input_from_server: ReconcilableState:
	set(value):
		forwarded_input_from_server = value
		_get_configuration_warnings()

var _partner_state_configuration_warning := ""

var root: Node:
	get:
		return get_node_or_null(root_path)

var _rollback_buffer: RollbackBuffer

## Debug buffer for tracking rollback/fast-forward/delay metrics (preview mode only).
var _debug_frame_buffer: RollbackBuffer


func _init() -> void:
	if Engine.is_editor_hint():
		return

	Netcode.log.ensure(
		Utils.check_whether_sub_classes_are_tools(self ),
		"Subclasses of ReconcilableState must be marked with @tool")


func _enter_tree() -> void:
	if Engine.is_editor_hint():
		return
	Netcode.frame_driver.add_networked_state(self )


func _exit_tree() -> void:
	if Engine.is_editor_hint():
		return

	# Release any pending bundle states.
	if not _pending_bundle_predicted.is_empty():
		ArrayPool.release(_pending_bundle_predicted)
		_pending_bundle_predicted = []
	if not _pending_bundle_authoritative.is_empty():
		ArrayPool.release(_pending_bundle_authoritative)
		_pending_bundle_authoritative = []

	# Invalidate bundler lookup cache.
	if (
		Netcode.state_bundler != null
		and Netcode.is_bundled_send
	):
		Netcode.state_bundler.clear_lookup()

	Netcode.frame_driver.remove_networked_state(self )


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

	_update_replication_config()
	_update_partner_state()
	update_configuration_warnings()

	if Engine.is_editor_hint():
		return

	if _rollback_buffer == null:
		_set_up_rollback_buffer()

	_parse_property_names()
	update_authority()

	# Register back-pressure visibility filter on
	# the server to skip sends when a WebSocket
	# peer's outbound buffer is nearly full.
	if Netcode.is_server or Netcode.is_local_mode:
		add_visibility_filter(
			_back_pressure_filter)

	# Re-process any state that arrived before _ready() (e.g., spawn data).
	# Before _parse_property_names(), _unpack_networked_state() fails the
	# size check. Either channel could receive data before _ready() via
	# MultiplayerSynchronizer.
	if not authoritative_packed_state.is_empty():
		_handle_new_state_from_network(authoritative_packed_state)
	if not predicted_packed_state.is_empty():
		_handle_new_state_from_network(predicted_packed_state)


func _parse_property_names() -> void:
	_property_names_for_packing.assign(
		get("_synced_properties_and_rollback_diff_thresholds").keys(),
	)
	for i in range(_property_names_for_packing.size()):
		var property_name := _property_names_for_packing[i]
		_property_name_to_pack_index[property_name] = i

	# Build type layout from default values for raw
	# byte packing. Each property is classified as
	# INT, FLOAT, or VECTOR2.
	var defaults := _get_default_values()
	_pack_types.clear()
	_pack_byte_size = 0
	for i in range(defaults.size()):
		var value = defaults[i]
		if value is Vector2:
			_pack_types.append(PackType.VECTOR2)
			_pack_byte_size += 8
		elif value is float:
			_pack_types.append(PackType.FLOAT)
			_pack_byte_size += 4
		else:
			_pack_types.append(PackType.INT)
			_pack_byte_size += 4
	# frame_authority (1 byte) + frame_index (4 bytes).
	_pack_byte_size += 5


func update_authority() -> void:
	var previous_authority_id := get_multiplayer_authority()
	set_multiplayer_authority(authority_id)
	if previous_authority_id != authority_id:
		Netcode.log.print(
			(
				"%s authority changed: %d -> %d "
				+"(server_auth=%s, peer_id=%d, is_local_auth=%s)"
			) % [
				name,
				previous_authority_id,
				authority_id,
				is_server_authoritative,
				peer_id,
				is_multiplayer_authority(),
			],
			NetworkLogger.CATEGORY_NETWORK_SYNC)


func _should_use_network_simulator() -> bool:
	return (
		Netcode.is_debug
		and Netcode.condition_simulator != null
		and Netcode.condition_simulator.is_enabled
	)


## Assign packed state to the replication property, triggering
## MultiplayerSynchronizer to send it on the next network tick.
## When bundling is active, the state is stored as the latest
## pending state per channel for StateBundler to collect.
func _assign_outgoing_state(
	state: Array,
	channel: StringName,
) -> void:
	if Netcode.is_bundled_send:
		if channel == NetworkConditionSimulator.CHANNEL_PREDICTED:
			if not _pending_bundle_predicted.is_empty():
				ArrayPool.release(
					_pending_bundle_predicted)
			_pending_bundle_predicted = state
		else:
			if not _pending_bundle_authoritative.is_empty():
				ArrayPool.release(
					_pending_bundle_authoritative)
			_pending_bundle_authoritative = state
		return
	_is_packing_state_locally = true
	if channel == NetworkConditionSimulator.CHANNEL_PREDICTED:
		if not predicted_packed_state.is_empty():
			ArrayPool.release(predicted_packed_state)
		predicted_packed_state = state
	else:
		if not authoritative_packed_state.is_empty():
			ArrayPool.release(authoritative_packed_state)
		authoritative_packed_state = state
	_is_packing_state_locally = false


## Return and clear all pending bundle states.
## Called by StateBundler to collect states for
## serialization into a single bundle packet.
func consume_pending_bundle_states() -> Array:
	var states: Array = []
	if not _pending_bundle_predicted.is_empty():
		states.append(_pending_bundle_predicted)
		_pending_bundle_predicted = []
	if not _pending_bundle_authoritative.is_empty():
		states.append(_pending_bundle_authoritative)
		_pending_bundle_authoritative = []
	return states


func _handle_new_state_from_network(p_state: Array) -> void:
	if p_state.is_empty():
		# Ignore any initial empty state.
		return

	var state_frame_index: int = _get_packed_frame_index(p_state)

	# Extract the frame authority from the received state.
	var new_frame_authority: int = _get_packed_authority(p_state)

	# PAUSE FILTERING: Reject states from after pause started.
	if Netcode.frame_driver.is_paused:
		var pause_frame: int = Netcode.frame_driver.pause_start_frame
		if state_frame_index > pause_frame:
			if Netcode.log.is_verbose:
				Netcode.log.verbose(
					"%s F:%d Rejecting state from frame %d (after pause at %d)" % [
						name,
						Netcode.server_frame_index,
						state_frame_index,
						pause_frame,
					],
					NetworkLogger.CATEGORY_NETWORK_SYNC)
			return

	# COUNTDOWN FILTERING: Reject client states during countdown.
	# Only applies to client-authoritative nodes on the server (input states).
	# Server-authoritative states (spawn positions, etc.) are always accepted.
	var is_during_countdown := (
		state_frame_index
		< Netcode.frame_driver
			.match_start_countdown_end_frame_index
	)
	if is_during_countdown and Netcode.is_server:
		if Netcode.log.is_verbose:
			Netcode.log.verbose(
				"%s F:%d Rejecting client state from frame %d (during countdown)" % [
					name,
					Netcode.server_frame_index,
					state_frame_index,
				],
				NetworkLogger.CATEGORY_NETWORK_SYNC)
		return

	if Netcode.log.is_verbose:
		var authority_string: StringName = FrameAuthority.keys()[new_frame_authority]
		Netcode.log.verbose(
			"%s F:%d Received %s state for frame %d"
			% [
				name,
				Netcode.server_frame_index,
				authority_string,
				state_frame_index,
			],
			NetworkLogger.CATEGORY_NETWORK_SYNC)

	# Filter SERVER_PREDICTED state based on node type:
	# - Owning clients should ignore SERVER_PREDICTED for their own character
	#   (their CLIENT_PREDICTED is based on authoritative input, so it's better).
	# - Remote clients should accept SERVER_PREDICTED (they only have forwarded
	#   input, so server's prediction is useful).
	# - Some nodes (like ForwardedPlayerInputFromServer) always need predicted
	#   states because they have no local prediction alternative.
	if (
		is_server_authoritative
		and Netcode.is_client
		and new_frame_authority == FrameAuthority.SERVER_PREDICTED
		and not _should_accept_predicted_states()
	):
		if Netcode.log.is_verbose:
			Netcode.log.verbose(
				"%s F:%d Ignoring SERVER_PREDICTED state for frame %d"
				% [
					name,
					Netcode.server_frame_index,
					state_frame_index,
				],
				NetworkLogger.CATEGORY_NETWORK_SYNC)
		return

	# Allow first state through even if "too old" (initial spawn data from frame 0).
	# After receiving valid state once, apply normal frame filtering.
	if _has_received_valid_state and Netcode.frame_driver.is_frame_too_old_to_consider(state_frame_index):
		if (
			not is_during_countdown
			and Netcode.log.is_verbose
		):
			Netcode.log.verbose(
				(
					"Received networked state that is too old to reconcile - "
					+"DISCARDING: state frame: %d, local frame: %d, "
					+"oldest acceptable: %d"
				) % [
					state_frame_index,
					Netcode.server_frame_index,
					Netcode.frame_driver.oldest_rollbackable_frame_index,
				],
				NetworkLogger.CATEGORY_NETWORK_SYNC)
		return

	var should_trigger_fast_forward := (
		Netcode.server_frame_index < state_frame_index - 1 and Netcode.is_client
	)
	var is_more_than_one_frame_ahead := Netcode.server_frame_index < state_frame_index - 2

	# Server rejects client states that are too far in the future
	# (3+ frames ahead). Under packet loss, input arrives in
	# bursts after gaps, so this is expected under bad conditions.
	if Netcode.is_server and is_more_than_one_frame_ahead:
		# Suppress during grace period after frame reset
		# (expected during reconnection).
		if (
			not Netcode.frame_driver.is_in_sync_grace_period
			and Netcode.log.is_verbose
		):
			Netcode.log.verbose(
				(
					"Rejecting too-distant-future state from "
					+"client: state frame %d, server frame %d"
				) % [
					state_frame_index,
					Netcode.server_frame_index,
				],
				NetworkLogger.CATEGORY_NETWORK_SYNC)
		return

	# Unpack if state is for current frame, next frame, or past. State for the
	# next frame is valid when received between physics ticks.
	# Also unpack first state regardless of frame (initial spawn data).
	var is_first_state := not _has_received_valid_state
	var should_unpack_state := (
		state_frame_index >= Netcode.server_frame_index
		or is_first_state
	)
	# Use <= so that input arriving for the current frame (between
	# physics ticks, before server_frame_index is incremented) also
	# triggers mismatch detection. Without this, 1-tick-late input on
	# localhost skips the check (N < N is false) and the character
	# state simulated with wrong predicted input is never corrected.
	var should_check_for_prediction_mismatch := (
		state_frame_index <= Netcode.server_frame_index
		and _rollback_buffer.has_at(state_frame_index)
		and new_frame_authority == FrameAuthority.AUTHORITATIVE
	)

	if should_check_for_prediction_mismatch:
		var mismatched_properties := _get_mismatched_properties(
			p_state, state_frame_index)
		if not mismatched_properties.is_empty():
			var buffer_state: Array = _rollback_buffer.get_at(state_frame_index)
			var node_type := (
				"state-from-server" if
				is_server_authoritative else
				"state-from-client"
			)
			var mismatch_details := _get_mismatch_details_string(
				mismatched_properties,
				p_state,
				buffer_state,
			)
			Netcode.log.verbose(
				"Mismatch at F:%d (%s): %s"
				% [state_frame_index, node_type,
				mismatch_details],
				NetworkLogger.CATEGORY_NETWORK_SYNC)

			# Queue rollback with detailed cause logging.
			var primary_cause := mismatched_properties[0] as String
			# For server-authoritative nodes (character state), the
			# buffer entry is overwritten by
			# _pack_buffer_state_from_network_state below, so re-sim
			# starts from the next frame (queue_rollback adds +1).
			# For client-authoritative nodes (input), only the input
			# buffer is corrected. The character state at the
			# mismatched frame was simulated with wrong input and
			# needs re-simulation, so we target one frame earlier.
			var rollback_frame := state_frame_index
			if not is_server_authoritative:
				rollback_frame -= 1
			Netcode.frame_driver.queue_rollback(
				rollback_frame,
				"%s mismatch on %s" % [
					primary_cause, name]
			)

			# Record rollback event in debug buffer.
			if _debug_frame_buffer != null:
				var entry = _debug_frame_buffer.get_at(state_frame_index)
				if entry != null:
					entry[_DEBUG_ROLLBACK_INDEX] = (
						Netcode.server_frame_index - state_frame_index
					)

			if Netcode.log.is_verbose:
				Netcode.log.verbose(
					"Rollback queued: frame=%d, cause=%s mismatch (%s)" % [
						state_frame_index,
						primary_cause,
						name
					],
					NetworkLogger.CATEGORY_NETWORK_SYNC
				)

		# Release the array back to pool.
		ArrayPool.release(mismatched_properties)

	# Record rollback buffer frame.
	_pack_buffer_state_from_network_state(p_state)

	# Record authoritative delay in debug buffer.
	if _debug_frame_buffer != null and new_frame_authority == FrameAuthority.AUTHORITATIVE:
		var entry := _get_or_create_debug_entry(state_frame_index)
		if entry != null:
			entry[_DEBUG_AUTHORITATIVE_STATE_DELAY_INDEX] = (
				Netcode.server_frame_index - state_frame_index
			)

	if should_unpack_state:
		# Record local class properties.
		_unpack_networked_state(p_state)
		frame_authority = new_frame_authority as FrameAuthority

		# Apply server state directly to scene when:
		# 1. This is the first state (initial spawn data), OR
		# 2. Network processing is skipped (paused or during countdown).
		# In both cases, _pre_network_process won't apply state normally.
		var is_network_processing_skipped := (
			Netcode.frame_driver.is_paused or is_during_countdown
		)
		var should_apply_directly := is_first_state or is_network_processing_skipped
		if should_apply_directly and is_server_authoritative and Netcode.is_client:
			_sync_to_scene_state(_get_default_values())

	# Mark that we've received valid state (for first-state bypass of too-old check).
	_has_received_valid_state = true

	received_network_state.emit(state_frame_index)

	# If we have skipped frames, we need to force the entire system to
	# fast-forward.
	if should_trigger_fast_forward:
		# After a hard backward reset, buffered state
		# packets from before the reset would race the
		# frame counter back up. Suppress fast-forwards
		# during the cooldown to let the NTP sync
		# stabilize.
		if Netcode.frame_driver.is_suppressing_fast_forward:
			return

		# During gradual catch-up, the frame driver
		# is already processing extra frames each
		# tick. The state is already buffered (above)
		# and will be reached naturally.
		if Netcode.frame_driver.is_catching_up:
			return

		# During gradual slow-down, the frame driver
		# is skipping ticks to let the server catch
		# up. Do not fast-forward.
		if Netcode.frame_driver.is_slowing_down:
			return

		Netcode.log.print(
			"Fast-forwarding due to future state"
			+ " from server",
			NetworkLogger.CATEGORY_NETWORK_SYNC)

		# Record fast-forward event in debug buffer
		# before fast-forwarding.
		if _debug_frame_buffer != null:
			var entry := _get_or_create_debug_entry(
				Netcode.server_frame_index)
			if entry != null:
				entry[_DEBUG_FAST_FORWARD_INDEX] = (
					state_frame_index - 1
					- Netcode.server_frame_index
				)

		Netcode.frame_driver.fast_forward(
			state_frame_index - 1)


func _network_process() -> void:
	network_processed.emit()


## This is called before _network_process is called on any nodes.
func _pre_network_process() -> void:
	# Initialize rollback buffer on first frame processing if not already done.
	# This happens on clients after time synchronization is complete.
	if _rollback_buffer == null:
		_set_up_rollback_buffer()
		# If still null, time isn't initialized yet - skip this frame.
		if _rollback_buffer == null:
			return

	frame_index = Netcode.server_frame_index
	frame_authority = FrameAuthority.UNKNOWN

	var latest_buffer_index := _rollback_buffer.get_latest_index()
	var is_first_frame_after_gap := latest_buffer_index < frame_index - 2

	# Skip buffer check if this is the first frame after a gap (e.g., countdown).
	# The buffer won't have previous frames, so we'll use defaults.
	if not is_first_frame_after_gap:
		Netcode.log.check(
			latest_buffer_index >= frame_index - 2,
			("Rollback buffer missing required frame: "
			+ "current=%d, needs=%d, latest=%d")
			% [
				frame_index,
				frame_index - 2,
				latest_buffer_index,
			])

	# We're about to simulate frame N. Start by loading frame N-1's final state
	# as our starting point, and provide frame N-2 as "previous" for just_*
	# comparisons (e.g., just_pressed, just_touched).
	if not is_first_frame_after_gap:
		_unpack_buffer_state(frame_index - 1)

	var previous_frame_state = _rollback_buffer.get_at(frame_index - 2)
	if previous_frame_state == null or is_first_frame_after_gap:
		# For very early frames or first frame after gap, use default values.
		previous_frame_state = _get_default_values()
	_sync_to_scene_state(previous_frame_state)

	# Restore indirect interaction-based state after syncing.
	var current_frame_state = _rollback_buffer.get_at(frame_index - 1)
	if current_frame_state != null:
		_restore_indirect_interaction_state(current_frame_state)


## This is called after _network_process has been called on all relevant nodes.
func _post_network_process() -> void:
	# Skip if rollback buffer isn't initialized yet (client before time sync).
	if _rollback_buffer == null:
		return

	_sync_from_scene_state()

	# Authority peers send their state over the network.
	# Skip during rollback re-simulation to avoid sending
	# past-frame states that confuse remote peers.
	# Throttle by send interval to reduce bandwidth.
	if (
		is_multiplayer_authority()
		and not Netcode.frame_driver.is_resimulating
		and (
			Netcode.server_frame_index
			% _get_send_interval()
		) == 0
	):
		_pack_networked_state()

	# All peers (authority and non-authority) pack local state into rollback
	# buffer to maintain buffer continuity. Non-authority peers will later
	# overwrite these frames with authoritative state when it arrives via
	# _pack_buffer_state_from_network_state().
	_pack_buffer_state_from_local_state()


func _get_is_server_authoritative() -> bool:
	Netcode.log.fatal(
		"Abstract ReconcilableNetworkState._get_is_server_authoritative is not implemented")
	return true


## Virtual method: identifies this node's role in the
## 3-node player architecture. Override in subclasses.
func _get_type() -> ReconcilableStateType:
	return ReconcilableStateType.GENERIC


## Virtual method: whether this node should accept SERVER_PREDICTED states from
## the server. Defaults to false (only accept AUTHORITATIVE states).
## Override to return true for nodes that need server predictions (like
## ForwardedPlayerInputFromServer, which has no local prediction alternative).
func _should_accept_predicted_states() -> bool:
	return false


## Virtual method: whether this node uses an additional
## predicted_packed_state replication channel alongside the primary
## authoritative_packed_state. Override to return true for nodes that need
## to send predicted and authoritative state simultaneously.
func _uses_split_packed_state() -> bool:
	return false


## Virtual method: whether this node should create a debug buffer for tracking
## rollback/fast-forward/delay metrics. Only active in preview mode.
## Override in subclasses that should track debug metrics.
func _should_create_debug_buffer() -> bool:
	return false


## Returns the send interval for this node.
## Subclasses override to use different rates
## (e.g., input always sends every frame).
## Default uses the global state send interval
## from FrameDriver.
func _get_send_interval() -> int:
	return Netcode.frame_driver.state_send_interval


## Visibility filter that skips sends when a
## WebSocket peer's outbound buffer is under
## pressure.
func _back_pressure_filter(peer_id: int) -> bool:
	return not Netcode.connector.is_peer_buffer_overloaded(
		peer_id
	)


## Get or create a debug buffer entry at the specified frame index.
## Unlike backfill_to_with_last_state(), this creates entries with default
## values to avoid propagating rollback/fast-forward markers from other frames.
func _get_or_create_debug_entry(frame_index: int) -> Variant:
	var entry = _debug_frame_buffer.get_at(frame_index)
	if entry != null:
		return entry

	# Frame doesn't exist, create with defaults.
	var new_entry := ArrayPool.acquire(3)
	new_entry[0] = 0 # No rollback.
	new_entry[1] = 0 # No fast-forward.
	new_entry[2] = -1 # Auth delay not yet received.
	if not _debug_frame_buffer.set_at(
			frame_index, new_entry):
		ArrayPool.release(new_entry)
		return null

	# Get the actual stored entry (set_at may
	# have copied to existing array).
	return _debug_frame_buffer.get_at(frame_index)


## Virtual method: whether this class uses the interaction tracking system.
## Must be overridden by subclasses to return true if they track interactions
## (regardless of whether they are rollbackable or non-rollbackable).
func _has_non_rollbackable_interactions() -> bool:
	Netcode.log.fatal(
		"Abstract ReconcilableNetworkState"
		+ "._has_non_rollbackable_interactions"
		+ " is not implemented"
	)
	return false


## Virtual method: whether a given interaction type is rollbackable.
## Defaults to true (all interactions can be recalculated during rollback).
## Override to return false for non-rollbackable interactions
## (server-authoritative interactions where the first impression is final).
func _is_interaction_rollbackable(_interaction_type: int) -> bool:
	Netcode.log.fatal(
		"Abstract ReconcilableNetworkState._is_interaction_rollbackable is not implemented")
	return true


func _get_default_values() -> Array:
	Netcode.log.fatal(
		"Abstract ReconcilableNetworkState._get_default_values is not implemented")
	return []


## This will update the surrounding scene state to match the networked state.
func _sync_to_scene_state(_previous_state: Array) -> void:
	Netcode.log.fatal(
		"Abstract ReconcilableNetworkState._sync_to_scene_state is not implemented"
	)


## Virtual method: restore indirect scene state based on interaction type.
## This handles scene state that isn't directly synced in the rollback buffer
## (e.g., collision layers, visibility) but depends on the interaction state.
## Called after _sync_to_scene_state() to ensure derived state matches the
## restored frame.
func _restore_indirect_interaction_state(_frame_state: Array) -> void:
	Netcode.log.fatal(
		"Abstract ReconcilableNetworkState._restore_indirect_interaction_state is not implemented")
	pass


## This will update the networked state to match the surrounding scene state.
func _sync_from_scene_state() -> void:
	Netcode.log.fatal(
		"Abstract ReconcilableNetworkState._sync_from_scene_state is not implemented"
	)


func _update_replication_config() -> void:
	if Engine.is_editor_hint():
		return

	# When bundling is active, skip registering
	# per-frame replication properties. StateBundler
	# handles sending instead of MultiplayerSynchronizer.
	if Netcode.is_bundled_send:
		return

	if not Netcode.log.ensure(is_instance_valid(root)):
		return

	var self_path: String = root.get_path_to(self )
	var authoritative_path := (
		"%s:authoritative_packed_state" % self_path
	)
	if not replication_config.has_property(authoritative_path):
		replication_config.add_property(authoritative_path)
	if _uses_split_packed_state():
		var predicted_path := (
			"%s:predicted_packed_state" % self_path
		)
		if not replication_config.has_property(predicted_path):
			replication_config.add_property(predicted_path)


func _set_up_rollback_buffer() -> void:
	# Initialize the rollback buffer with the current frame index.
	# Frame indices start at 0 and are immediately valid (no time sync needed).
	var default_values := _get_default_values().duplicate()
	var default_authority := (
		FrameAuthority.SERVER_PREDICTED
		if Netcode.is_server
		else FrameAuthority.CLIENT_PREDICTED
	)
	default_values.append(default_authority)

	_rollback_buffer = RollbackBuffer.new(
		Netcode.frame_driver.rollback_buffer_size,
		Netcode.frame_driver.server_frame_index,
		default_values,
	)

	# Create debug buffer alongside rollback buffer (preview mode only).
	if Netcode.is_debug and _should_create_debug_buffer():
		_debug_frame_buffer = RollbackBuffer.new(
			Netcode.frame_driver.rollback_buffer_size,
			Netcode.frame_driver.server_frame_index,
			_DEBUG_DEFAULT_ENTRY.duplicate(),
		)


func _has_authoritative_state_for_current_frame() -> bool:
	if not _rollback_buffer.has_at(Netcode.server_frame_index):
		return false
	var frame_data: Array = _rollback_buffer.get_at(Netcode.server_frame_index)
	return frame_data[frame_data.size() - 1] == FrameAuthority.AUTHORITATIVE


func _pack_networked_state() -> void:
	var state := ArrayPool.acquire(_property_names_for_packing.size() + 2)

	var i := 0
	for property_name in _property_names_for_packing:
		state[i] = get(property_name)
		i += 1
	state[i] = frame_authority
	i += 1
	# Send frame index directly.
	state[i] = frame_index

	if Netcode.log.is_verbose:
		var authority_string: StringName = FrameAuthority.keys()[frame_authority]
		if not is_server_authoritative:
				Netcode.log.verbose(
					"%s F:%d Packed client-auth state (%s)"
					% [
						name,
						Netcode.server_frame_index,
						authority_string,
					],
					NetworkLogger.CATEGORY_NETWORK_SYNC)
		else:
			Netcode.log.verbose(
				"%s F:%d Packed server-auth state (%s)"
				% [
					name,
					Netcode.server_frame_index,
					authority_string,
				],
				NetworkLogger.CATEGORY_NETWORK_SYNC)

	var channel: StringName = (
		NetworkConditionSimulator.CHANNEL_PREDICTED
		if _uses_split_packed_state()
		else NetworkConditionSimulator.CHANNEL_AUTHORITATIVE
	)

	if _should_use_network_simulator():
		Netcode.condition_simulator.queue_outgoing_state(
			self , state, channel)
	else:
		_assign_outgoing_state(state, channel)


func _unpack_networked_state(p_state: Array) -> void:
	# Empty state is expected and normal during initial sync. When a
	# ReconcilableState is first created, MultiplayerSynchronizer may
	# trigger a sync before we've packed any state.
	if p_state.is_empty():
		return

	if not Netcode.log.ensure(
			p_state.size() == _property_names_for_packing.size() + 2):
		return

	# Unpack all properties from network unconditionally.
	# Protection for non-rollbackable state is in packing functions, not here.
	var i := 0
	for property_name in _property_names_for_packing:
		set(property_name, p_state[i])
		i += 1
	# Skip frame_authority (at index i) - we handle it separately in _handle_new_state_from_network.
	i += 1
	# Unpack frame index directly.
	frame_index = _get_packed_frame_index(p_state)


func _pack_buffer_state_from_local_state() -> void:
	# Check if buffer has a non-rollbackable interaction onset that
	# must be preserved. Only onset frames need protection (where
	# last_interaction_frame_index == frame_index), not continuation frames.
	if _rollback_buffer.has_at(frame_index):
		var existing_state: Array = _rollback_buffer.get_at(frame_index)
		var existing_interaction_type: int = _get_frame_property(
			existing_state,
			&"last_interaction_type"
		)
		var existing_interaction_frame: int = _get_frame_property(
			existing_state,
			&"last_interaction_frame_index"
		)

		# Check if buffer has non-rollbackable onset. at THIS frame.
		var is_onset := (existing_interaction_frame == frame_index)
		var is_non_rollbackable := not _is_interaction_rollbackable(
			existing_interaction_type
		)
		var is_frame_locked := is_onset and is_non_rollbackable

		if is_frame_locked:
			# Buffer has authoritative onset - preserve interaction properties,
			# but always update physics state (position, velocity).
			if Netcode.log.is_verbose and last_interaction_type != existing_interaction_type:
				Netcode.log.verbose(
					("Preserving onset %s from buffer, "
					+ "not overwriting with local %s "
					+ "at frame %d (%s)")
					% [
						_get_interaction_type_name(
							existing_interaction_type),
						_get_interaction_type_name(
							last_interaction_type),
						frame_index,
						name,
					],
					NetworkLogger.CATEGORY_NETWORK_SYNC
				)

			# Pack hybrid state: interaction from buffer, physics from local.
			var preserved_state := ArrayPool.acquire(
				_property_names_for_packing.size() + 1
			)
			var index := 0
			for property_name in _property_names_for_packing:
				if property_name.begins_with("last_interaction_"):
					# Preserve interaction properties from buffer.
					preserved_state[index] = _get_frame_property(
						existing_state,
						property_name
					)
				else:
					# Pack current local value (position, velocity, etc.).
					preserved_state[index] = get(property_name)
				index += 1
			preserved_state[index] = frame_authority

			# Note: state is owned by rollback buffer, don't release.
			_record_buffer_frame(frame_index, preserved_state)
			return

	# Normal packing: no onset to preserve.
	var state := ArrayPool.acquire(_property_names_for_packing.size() + 1)

	var i := 0
	for property_name in _property_names_for_packing:
		state[i] = get(property_name)
		i += 1
	state[i] = frame_authority

	# Note: state is now owned by the rollback buffer, don't release it here.
	_record_buffer_frame(frame_index, state)


## Records the current state in the rollback buffer at the current simulated
## frame index.
##
## This does _not_ record state in the packed state array for syncing across the
## network.
func _pack_buffer_state_from_network_state(packed_network_state: Array) -> void:
	var frame_index: int = _get_packed_frame_index(packed_network_state)
	var new_frame_authority: int = _get_packed_authority(packed_network_state)

	# Check if network has NONE but buffer has non-rollbackable onset.
	# Client: FATAL error (server should never send NONE for onset).
	# Server: Reject bogus client state (prevents malicious/buggy clients).
	var interaction_prop_index := _property_name_to_pack_index.get(
		&"last_interaction_type",
		-1
	) as int
	var network_interaction_type: int = packed_network_state[interaction_prop_index]

	if (
		network_interaction_type == _NONE_INTERACTION_TYPE
		and _rollback_buffer.has_at(frame_index)
	):
		var existing_state: Array = _rollback_buffer.get_at(frame_index)
		var existing_interaction_type: int = _get_frame_property(
			existing_state,
			&"last_interaction_type"
		)
		var existing_interaction_frame: int = _get_frame_property(
			existing_state,
			&"last_interaction_frame_index"
		)

		# Check if buffer has non-rollbackable onset.
		var is_onset := (existing_interaction_frame == frame_index)
		var is_non_rollbackable := not _is_interaction_rollbackable(existing_interaction_type)
		var is_frame_locked := is_onset and is_non_rollbackable

		if is_frame_locked:
			if Netcode.is_client:
				# CLIENT: Server should never send NONE for onset.
				Netcode.log.fatal(
					("Network NONE from server "
					+ "attempting to overwrite "
					+ "non-rollbackable onset %s "
					+ "at frame %d - critical "
					+ "server bug! (%s)")
					% [
						_get_interaction_type_name(
							existing_interaction_type),
						frame_index,
						name,
					]
				)
				return
			else:
				# SERVER: Reject bogus client state and log error.
				Netcode.log.error(
					("Rejecting network NONE from "
					+ "client attempting to overwrite "
					+ "non-rollbackable onset %s "
					+ "at frame %d - bogus client "
					+ "state (%s)")
					% [
						_get_interaction_type_name(
							existing_interaction_type),
						frame_index,
						name,
					],
					NetworkLogger.CATEGORY_NETWORK_SYNC
				)
				# Don't pack the bogus network state. Keep buffer's onset intact.
				return

	# Normal packing. Network state is authoritative and valid.
	# For the rollback buffer, we use the same state layout as the network state,
	# but we replace the timestamp with the frame_authority from the sender.
	var rollback_frame_state := ArrayPool.acquire(packed_network_state.size() - 1)

	for i in range(packed_network_state.size() - 2):
		rollback_frame_state[i] = packed_network_state[i]
	rollback_frame_state[rollback_frame_state.size() - 1] = new_frame_authority

	# Note: rollback_frame_state is now owned by the rollback
	# buffer, don't release it here.
	_record_buffer_frame(frame_index, rollback_frame_state)


func _record_buffer_frame(frame_index: int, frame_state: Array) -> void:
	# TODO: When updating frame buffer state later, reference the
	# preexisting frame array, rather than instantiating a new one.
	# Guard against null rollback buffer. For tests: can occur if time
	# isn't initialized yet when record_initial_state() is called
	# during _ready().
	if _rollback_buffer == null:
		# Release the frame_state array since we can't store it.
		ArrayPool.release(frame_state)
		return

	_rollback_buffer.backfill_to_with_last_state(frame_index - 1)

	_rollback_buffer.set_at(frame_index, frame_state)


## Reinitialize rollback buffer after a hard frame reset.
##
## When the frame index jumps backward, the buffer may contain stale predicted
## data at the new frame indices. This method reinitializes the buffer using
## CURRENT scene state (not defaults) to prevent teleporting characters.
func _reinitialize_buffer_for_hard_reset(new_frame_index: int) -> void:
	if _rollback_buffer == null:
		return

	# Skip if properties haven't been parsed yet.
	if _property_names_for_packing.is_empty():
		return

	# Sync current scene state to networked properties first.
	_sync_from_scene_state()

	# Create fill state from current scene state (not defaults).
	var fill_state := ArrayPool.acquire(_property_names_for_packing.size() + 1)
	var i := 0
	for property_name in _property_names_for_packing:
		fill_state[i] = get(property_name)
		i += 1
	# Mark as predicted so authoritative state can overwrite.
	var fill_authority := (
		FrameAuthority.SERVER_PREDICTED
		if Netcode.is_server
		else FrameAuthority.CLIENT_PREDICTED
	)
	fill_state[i] = fill_authority

	# Reinitialize the entire buffer with current state at new frame index.
	_rollback_buffer._reinitialize_data(fill_state, new_frame_index)

	# Release the temporary fill state (buffer made its own copies).
	ArrayPool.release(fill_state)

	# Also reinitialize debug buffer if present.
	if _debug_frame_buffer != null:
		_debug_frame_buffer._reinitialize_data(
			_DEBUG_DEFAULT_ENTRY.duplicate(),
			new_frame_index
		)

	if Netcode.log.is_verbose:
		Netcode.log.verbose(
			"%s buffer reinitialized for hard reset to frame %d" % [
				name,
				new_frame_index,
			],
			NetworkLogger.CATEGORY_NETWORK_SYNC
		)


## Clean up rollback buffer state after pause started.
##
## Back-fills all frames after the pause frame with the pause frame's state
## marked as predicted. This prevents mismatch detection from comparing
## pre-pause server state with invalid post-pause predictions.
func _cleanup_buffer_after_pause(pause_frame: int) -> void:
	# Get pause frame state.
	if not _rollback_buffer.has_at(pause_frame):
		return

	var pause_state: Array = _rollback_buffer.get_at(pause_frame)

	# Create a copy marked as predicted for resetting.
	var fill_state := ArrayPool.acquire(pause_state.size())
	for i in range(pause_state.size() - 1):
		fill_state[i] = pause_state[i]
	var fill_authority := (
		FrameAuthority.SERVER_PREDICTED
		if Netcode.is_server
		else FrameAuthority.CLIENT_PREDICTED
	)
	fill_state[fill_state.size() - 1] = fill_authority

	# Reset from pause_frame+1 to current latest.
	var latest := _rollback_buffer.get_latest_index()
	for frame_index in range(pause_frame + 1, latest + 1):
		var frame_state := ArrayPool.acquire(fill_state.size())
		for i in range(fill_state.size()):
			frame_state[i] = fill_state[i]
		_rollback_buffer.set_at(frame_index, frame_state)

	ArrayPool.release(fill_state)

	# Also reset debug buffer entries after pause.
	if _debug_frame_buffer != null:
		for frame_index in range(pause_frame + 1, latest + 1):
			var entry := ArrayPool.acquire(3)
			entry[0] = 0
			entry[1] = 0
			entry[2] = -1
			_debug_frame_buffer.set_at(frame_index, entry)


## Records the initial spawn state to the rollback buffer for the current
## frame and previous frames.
##
## This should be called (deferred) after _ready() completes to ensure the
## ReconcilableState's _ready() has finished setting up the buffer.
## It prevents _pre_network_process from loading default zero values from the
## buffer on the first frame by pre-populating frames N-2, N-1, and N.
##
## All frames are marked as predicted (SERVER_PREDICTED on server,
## CLIENT_PREDICTED on client) so authoritative state can overwrite them.
##
## If include_partners is true (default), this will also record the initial
## state for the partner node if one exists (e.g., the client-authoritative
## input state paired with a server-authoritative character state).
func record_initial_state(include_partners := true) -> void:
	# Skip if properties haven't been parsed yet (can happen when called on
	# sibling nodes before their _ready() runs).
	if _property_names_for_packing.is_empty():
		return

	# Sync the current scene state to the networked properties.
	_sync_from_scene_state()

	# Create the initial state array with current property values.
	var initial_state := ArrayPool.acquire(
		_property_names_for_packing.size() + 1,
	)
	var i := 0
	for property_name in _property_names_for_packing:
		initial_state[i] = get(property_name)
		i += 1
	var initial_authority := (
		FrameAuthority.SERVER_PREDICTED
		if Netcode.is_server
		else FrameAuthority.CLIENT_PREDICTED
	)
	initial_state[i] = initial_authority

	# Record for N-2, N-1, and N.
	for frame_offset in range(-2, 1):
		var target_frame := (
			Netcode.server_frame_index + frame_offset
		)
		var frame_state := ArrayPool.acquire(initial_state.size())
		for j in range(initial_state.size()):
			frame_state[j] = initial_state[j]
		_record_buffer_frame(target_frame, frame_state)

	ArrayPool.release(initial_state)

	# Also pack to network state so MultiplayerSynchronizer
	# can replicate it. This is critical for spawn state during
	# countdown when _post_network_process doesn't run. Set
	# frame_index and frame_authority before packing. Guard:
	# only pack if properties have been parsed (sibling nodes
	# may not be ready yet).
	var has_peer := (
		multiplayer != null
		and multiplayer.multiplayer_peer != null
		and multiplayer.multiplayer_peer.get_connection_status()
			!= MultiplayerPeer.CONNECTION_DISCONNECTED
	)
	if (has_peer
			and is_multiplayer_authority()
			and not _property_names_for_packing.is_empty()):
		frame_index = Netcode.server_frame_index
		frame_authority = FrameAuthority.AUTHORITATIVE
		_pack_networked_state()

	# Also initialize the partner state if present.
	if include_partners:
		# Record initial state for all sibling nodes.
		if is_instance_valid(state_from_server):
			state_from_server.record_initial_state(false)
		if is_instance_valid(input_from_client):
			input_from_client.record_initial_state(false)
		if is_instance_valid(forwarded_input_from_server):
			forwarded_input_from_server.record_initial_state(false)


## Backfill the rollback buffer to the current frame.
## Called when countdown ends to fill the gap created by skipped network processing.
func backfill_buffer_to_current_frame() -> void:
	if _rollback_buffer == null:
		return
	var latest_before := _rollback_buffer.get_latest_index()
	_rollback_buffer.backfill_to_with_last_state(Netcode.server_frame_index - 1)
	if Netcode.log.is_verbose and is_server_authoritative:
		Netcode.log.verbose(
			"Backfilled %s buffer: %d -> %d (gap: %d frames)" % [
				name,
				latest_before,
				Netcode.server_frame_index - 1,
				(Netcode.server_frame_index - 1) - latest_before
			],
			NetworkLogger.CATEGORY_NETWORK_SYNC
		)


func _unpack_buffer_state(frame_index: int) -> void:
	var frame_state = _rollback_buffer.get_at(frame_index)

	# If no state exists for this frame (early in simulation or during
	# fast-forward), return early. The current state will be used as-is.
	if frame_state == null:
		return

	# Unpack all properties from buffer unconditionally.
	# Protection for non-rollbackable state is now in packing functions, not
	# here.
	# This allows pure state restoration for simulation setup.
	var i := 0
	for property_name in _property_names_for_packing:
		set(property_name, frame_state[i])
		i += 1
	frame_authority = frame_state[i]


## Checks if the given frame is a non-rollbackable interaction onset.
func _is_non_rollbackable_interaction_onset(
	frame_state: Array,
	frame_index: int
) -> bool:
	var interaction_type: int = _get_frame_property(
		frame_state,
		&"last_interaction_type"
	)
	var interaction_frame: int = _get_frame_property(
		frame_state,
		&"last_interaction_frame_index"
	)

	# This is an interaction onset frame if the interaction frame equals this
	# frame.
	if interaction_frame != frame_index:
		return false

	# Check if the interaction is non-rollbackable.
	return not _is_interaction_rollbackable(interaction_type)


## Gets a property value from a frame state array by property name.
func _get_frame_property(frame_state: Array, property_name: StringName) -> Variant:
	var pack_index: int = _property_name_to_pack_index[property_name]
	return frame_state[pack_index]


## Sets a property value in a frame state array by property name.
func _set_frame_property(
	frame_state: Array,
	property_name: StringName,
	value: Variant
) -> void:
	var pack_index: int = _property_name_to_pack_index[property_name]
	frame_state[pack_index] = value


## Gets the frame authority from a frame state array (rollback buffer format).
func _get_frame_authority(frame_state: Array) -> FrameAuthority:
	var authority_index := frame_state.size() - 1
	return frame_state[authority_index] as FrameAuthority


## Sets the frame authority in a frame state array (rollback buffer format).
func _set_frame_authority(
	frame_state: Array,
	authority: FrameAuthority
) -> void:
	var authority_index := frame_state.size() - 1
	frame_state[authority_index] = authority


## Checks if a frame state has authoritative authority.
func _is_frame_authoritative(frame_state: Array) -> bool:
	return _get_frame_authority(frame_state) == FrameAuthority.AUTHORITATIVE


## Checks if a frame state has any predicted authority (server or client).
func _is_frame_predicted(frame_state: Array) -> bool:
	var authority := _get_frame_authority(frame_state)
	return (
		authority == FrameAuthority.SERVER_PREDICTED
		or authority == FrameAuthority.CLIENT_PREDICTED
	)


## Checks if a frame state has server-predicted authority.
func _is_frame_server_predicted(frame_state: Array) -> bool:
	return _get_frame_authority(frame_state) == FrameAuthority.SERVER_PREDICTED


## Checks if a frame state has client-predicted authority.
func _is_frame_client_predicted(frame_state: Array) -> bool:
	return _get_frame_authority(frame_state) == FrameAuthority.CLIENT_PREDICTED


## Gets the frame index from a packed state array (network format).
func _get_packed_frame_index(packed_network_state: Array) -> int:
	return packed_network_state[packed_network_state.size() - 1]


## Gets the frame authority from a packed state array (network format).
func _get_packed_authority(packed_network_state: Array) -> FrameAuthority:
	var authority_index := packed_network_state.size() - 2
	return packed_network_state[authority_index] as FrameAuthority


## Returns an array of property names that have mismatched values between
## networked state and local buffer state.
##
## Uses ArrayPool to reduce allocations since this is called frequently on the
## network hot path. Caller is responsible for releasing the array.
func _get_mismatched_properties(
	networked_state: Array,
	frame_index: int,
) -> Array:
	var buffer_data: Array = _rollback_buffer.get_at(frame_index)
	var thresholds: Dictionary = get("_synced_properties_and_rollback_diff_thresholds")

	# Pre-allocate for worst case (all properties mismatched).
	var mismatched := ArrayPool.acquire(thresholds.size())
	var mismatch_count := 0

	for property_name in thresholds:
		var threshold = thresholds[property_name]
		var pack_index: int = _property_name_to_pack_index[property_name]
		var networked_value = networked_state[pack_index]
		var buffer_value = buffer_data[pack_index]
		if _check_do_values_mismatch(buffer_value, networked_value, threshold):
			mismatched[mismatch_count] = property_name
			mismatch_count += 1

	# Trim to actual size.
	mismatched.resize(mismatch_count)
	return mismatched


## Returns a formatted string showing only the mismatched properties and their
## values from both networked and local buffer state.
func _get_mismatch_details_string(
	mismatched_properties: Array,
	networked_state: Array,
	buffer_state: Array,
) -> String:
	var details: Array[String] = []
	for property_name in mismatched_properties:
		var pack_index: int = _property_name_to_pack_index[property_name]
		var networked_value = networked_state[pack_index]
		var buffer_value = buffer_state[pack_index]

		# Special formatting for interaction properties.
		if property_name.contains("interaction"):
			if property_name == "last_interaction_type":
				var buffer_type_str := _get_interaction_type_name(buffer_value)
				var networked_type_str := _get_interaction_type_name(networked_value)
				details.append(
					"{%s: local=%s, remote=%s}"
					% [property_name,
					buffer_type_str,
					networked_type_str],
				)
			elif property_name == "last_interaction_frame_index":
				var drift := absi(buffer_value - networked_value)
				details.append(
					("{%s: local=%d, remote=%d,"
					+ " drift=%d}")
					% [property_name,
					buffer_value,
					networked_value, drift],
				)
			elif property_name in ["last_interaction_position", "last_interaction_velocity"]:
				var dist := (buffer_value as Vector2).distance_to(networked_value)
				details.append(
					"{%s: distance=%.3f}"
					% [property_name, dist],
				)
		else:
			var networked_str := _get_string_for_value(networked_value)
			var buffer_str := _get_string_for_value(buffer_value)
			details.append(
				"{%s: local=%s, remote=%s}"
				% [property_name,
				buffer_str, networked_str],
			)

	return ", ".join(details)


func _check_do_values_mismatch(
	buffer_value: Variant,
	networked_value: Variant,
	threshold: Variant,
) -> bool:
	# Negative threshold disables mismatch detection for this
	# property (used when redundant input makes interaction
	# metadata rollbacks unnecessary).
	if (
		typeof(threshold) in [TYPE_INT, TYPE_FLOAT]
		and threshold < 0
	):
		return false
	match typeof(buffer_value):
		TYPE_BOOL, TYPE_STRING:
			return buffer_value != networked_value
		TYPE_INT, TYPE_FLOAT:
			if threshold == 0:
				# Threshold of 0 means exact match required.
				return buffer_value != networked_value
			else:
				return abs(buffer_value - networked_value) >= threshold
		TYPE_VECTOR2, TYPE_VECTOR2I:
			if threshold == 0:
				# Threshold of 0 means exact match required.
				return buffer_value != networked_value
			else:
				return buffer_value.distance_squared_to(networked_value) >= threshold * threshold
		_:
			Netcode.log.fatal(
				("Type not yet supported for "
				+ "client-prediction mismatch "
				+ "threshold calculations: %s")
				% type_string(buffer_value))
			return true


func _update_partner_state() -> void:
	if not is_node_ready():
		# Don't try parsing siblings until we're actually in the tree.
		return

	# Clear all sibling references.
	state_from_server = null
	input_from_client = null
	forwarded_input_from_server = null

	# Collect all sibling ReconcilableState nodes and categorize them.
	var sibling_states: Array[ReconcilableState] = []
	for child in get_parent().get_children():
		if child is ReconcilableState and child != self:
			sibling_states.append(child)

			# Populate named properties based on node role.
			match child._get_type():
				ReconcilableStateType.CHARACTER_STATE:
					state_from_server = child
				ReconcilableStateType.INPUT_FROM_CLIENT:
					input_from_client = child
				ReconcilableStateType.FORWARDED_INPUT:
					forwarded_input_from_server = child

	# Validate the node configuration.
	# Only 1-node or 3-node (client-controlled player) are valid.
	if sibling_states.size() == 0:
		# Valid 1-node setup (NPC with only CharacterStateFromServer).
		if is_client_authoritative:
			_partner_state_configuration_warning = ("A client-authoritative ReconcilableState node must be accompanied by a server-authoritative ReconcilableState sibling node")
	elif sibling_states.size() == 1:
		# Invalid 2-node setup. Players now require the full 3-node setup.
		_partner_state_configuration_warning = (
			"Either CharacterStateFromServer must be by itself, or there "
			+"must be three nodes (for client-controlled players): "
			+"CharacterStateFromServer + PlayerInputFromClient + "
			+"ForwardedPlayerInputFromServer"
		)
	elif sibling_states.size() == 2:
		# 3-node configuration: 1 client-auth + 2 server-auth.
		var client_auth_count := 0
		var server_auth_count := 0

		# Count self.
		if is_client_authoritative:
			client_auth_count += 1
		else:
			server_auth_count += 1

		# Count siblings.
		for sibling in sibling_states:
			if sibling.is_client_authoritative:
				client_auth_count += 1
			else:
				server_auth_count += 1

		# Validate configuration: must be 1 client + 2 server (including self).
		if client_auth_count == 1 and server_auth_count == 2:
			# Valid 3-node setup.
			# Validate that we found the two expected sibling types.
			# (The third type is self, so it won't be in the sibling list.)
			var state_type := _get_type()
			if state_type == ReconcilableStateType.CHARACTER_STATE:
				if input_from_client == null or forwarded_input_from_server == null:
					_partner_state_configuration_warning = ("CharacterStateFromServer requires PlayerInputFromClient and ForwardedPlayerInputFromServer siblings")
			elif state_type == ReconcilableStateType.INPUT_FROM_CLIENT:
				if state_from_server == null or forwarded_input_from_server == null:
					_partner_state_configuration_warning = ("PlayerInputFromClient requires CharacterStateFromServer and ForwardedPlayerInputFromServer siblings")
			elif state_type == ReconcilableStateType.FORWARDED_INPUT:
				if state_from_server == null or input_from_client == null:
					_partner_state_configuration_warning = ("ForwardedPlayerInputFromServer requires CharacterStateFromServer and PlayerInputFromClient siblings")
			else:
				_partner_state_configuration_warning = "" # Valid 3-node setup.
		else:
			_partner_state_configuration_warning = ("3-node configuration requires exactly 1 client-authoritative and 2 server-authoritative nodes")
	elif sibling_states.size() > 2:
		_partner_state_configuration_warning = ("There should be no more than 3 ReconcilableState nodes (1 client-auth + 2 server-auth for Player, or 1 server-auth for NPC)")

	if not Engine.is_editor_hint() and not _partner_state_configuration_warning.is_empty():
		# Log and assert in game runtime environments.
		Netcode.log.error(
			"ReconcilableState is misconfigured: %s"
			% _partner_state_configuration_warning,
			NetworkLogger.CATEGORY_CORE_SYSTEMS)

	# Also refresh sibling ReconcilableState warnings.
	# Trigger configuration warning updates on all siblings.
	if is_instance_valid(state_from_server):
		state_from_server.update_configuration_warnings()
	if is_instance_valid(input_from_client):
		input_from_client.update_configuration_warnings()
	if is_instance_valid(forwarded_input_from_server):
		forwarded_input_from_server.update_configuration_warnings()


func _get_configuration_warnings() -> PackedStringArray:
	var warnings: PackedStringArray = []

	var thresholds = get("_synced_properties_and_rollback_diff_thresholds")

	if thresholds == null:
		warnings.append(
			"A _synced_properties_and_rollback_diff_thresholds property must be defined on subclasses of ReconcilableState",
		)
	elif not thresholds is Dictionary:
		warnings.append(
			"The _synced_properties_and_rollback_diff_thresholds property must be a Dictionary",
		)
	else:
		# Check if _synced_properties_and_rollback_diff_thresholds matches the other properties.
		for property_name in thresholds.keys():
			if get(property_name) == null:
				warnings.append(
					("Key %s in _synced_properties"
					+ "_and_rollback_diff_thresholds"
					+ " does not match any class"
					+ " property")
					% property_name,
				)

	if root_path.is_empty():
		warnings.append("root_path must be defined")
	elif not is_instance_valid(root):
		warnings.append("root_path does not point to a valid node")
	elif not _partner_state_configuration_warning.is_empty():
		warnings.append(_partner_state_configuration_warning)

	# Validate interaction tracking configuration.
	if _has_non_rollbackable_interactions():
		var required_properties := [
			"last_interaction_type",
			"last_interaction_frame_index",
			"last_interaction_position",
			"last_interaction_velocity",
		]
		for prop in required_properties:
			if thresholds != null and not thresholds.has(prop):
				warnings.append(
					("Class has non-rollbackable "
					+ "interactions but missing "
					+ "'%s' in _synced_properties"
					+ "_and_rollback_diff_thresholds")
					% prop
				)

	return warnings


func get_string_for_packed_state(state: Array) -> String:
	var tokens: Array[String] = []
	tokens.resize(state.size())
	var i := 0
	for value in state:
		tokens[i] = _get_string_for_value(value, i == state.size() - 1)
		i += 1

	return "[%s]" % ",".join(tokens)


func _get_string_for_value(value, is_final_value := false) -> String:
	match typeof(value):
		TYPE_BOOL, TYPE_STRING:
			return str(value)
		TYPE_INT:
			# By default, we display int values as bitmasks.
			if is_final_value:
				return str(value)
			return _get_string_for_bitmask(value)
		TYPE_FLOAT:
			return "%.1f" % value
		TYPE_VECTOR2, TYPE_VECTOR2I:
			return Utils.get_vector_string(value, 1)
		_:
			Netcode.log.fatal(
				("Type not yet supported for "
				+ "rollback buffer: %s")
				% type_string(value))
			return ""


func _get_string_for_bitmask(value: int) -> String:
	return String.num_int64(value, 2).lpad(8, "0")


## Returns a human-readable name for an interaction type enum value.
## Subclasses can override this to provide specific enum names.
func _get_interaction_type_name(interaction_type: int) -> String:
	# Default implementation - subclasses should override.
	if interaction_type == _NONE_INTERACTION_TYPE:
		return "NONE"
	return str(interaction_type)


## Records an interaction by setting all interaction properties at once.
func record_interaction(
	interaction_type: int,
	frame_index: int,
	position: Vector2,
	velocity: Vector2
) -> void:
	# Never allow recording NONE interaction. NONE should only exist during
	# initialization before any real interaction occurs. Once an interaction is
	# recorded, it must persist until explicitly replaced by another non-NONE
	# interaction (e.g., DIE persists until SPAWN).
	if interaction_type == _NONE_INTERACTION_TYPE:
		Netcode.log.fatal(
			("Attempted to record NONE "
			+ "interaction. This should never "
			+ "happen! Current: %s, Frame: %d")
			% [
				_get_interaction_type_name(
					last_interaction_type),
				(Netcode.server_frame_index
					if Netcode else -1),
			]
		)
		return

	var old_type := last_interaction_type
	last_interaction_type = interaction_type
	last_interaction_frame_index = (
		frame_index if frame_index >= 0 else Netcode.server_frame_index
	)
	last_interaction_position = position
	last_interaction_velocity = velocity

	if Netcode.log.is_verbose and Netcode.is_server:
		Netcode.log.verbose(
			"[INTERACTION] Player %d: %s -> %s at frame %d" % [
				player_id,
				_get_interaction_type_name(old_type),
				_get_interaction_type_name(interaction_type),
				last_interaction_frame_index,
			],
			NetworkLogger.CATEGORY_GAME_STATE
		)


## Validates whether an interaction should be reconciled.
## Checks: frame not already processed, not too old, exists in buffer (in the
## future).
func _should_reconcile_interaction(
	interaction_frame: int,
	last_reconciled_frame: int
) -> bool:
	if interaction_frame <= last_reconciled_frame:
		return false
	if Netcode.frame_driver.is_frame_too_old_to_consider(interaction_frame):
		Netcode.log.warning(
			"Interaction too old to reconcile: frame %d" % interaction_frame,
			NetworkLogger.CATEGORY_NETWORK_SYNC,
		)
		return false
	if not _rollback_buffer.has_at(interaction_frame):
		return false
	return true
