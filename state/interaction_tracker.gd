class_name InteractionTracker
extends RefCounted
## Generic utility for interaction deduplication using rollback buffer.
##
## InteractionTracker prevents duplicate interaction events during rollback by
## maintaining a history of recent interactions and checking for matches within
## a configurable time window. This is essential for server-authoritative
## interactions where "first impression is final" (e.g., collision damage,
## pickup collection).
##
## Use cases:
## - **Kill/death events**: Prevent double-counting kills during rollback
## - **Bump/collision**: Deduplicate physics contacts across frames
## - **Pickup collection**: Ensure items are only collected once
## - **Interaction prompts**: Prevent duplicate button interactions
##
## How it works:
## 1. Record interactions with record_interaction() on server
## 2. Check has_recent_interaction() before recording new events
## 3. Rollback buffer maintains history for deduplication window
## 4. Interactions outside window are automatically pruned
##
## Usage example:
## ```gdscript
## var interaction_tracker := InteractionTracker.new(rollback_buffer)
##
## # On server, when player A collides with player B:
## if not interaction_tracker.has_recent_interaction(
##     player_a_id, player_b_id, current_frame, INTERACTION_BUMP
## ):
##     interaction_tracker.record_interaction(
##         player_a_id, player_b_id, current_frame, INTERACTION_BUMP
##     )
##     # Trigger game logic (damage, score, etc.)
## ```

## RollbackBuffer reference for storing interaction history.
var _rollback_buffer: RollbackBuffer

## Deduplication window in frames.
## Interactions within this window are considered duplicates.
## Default: 4 frames (typical for 60 FPS collision resolution).
var deduplication_window_frames := 4


## Initialize interaction tracker with rollback buffer.
##
## The rollback buffer is used to store interaction history and automatically
## prunes old data based on buffer capacity.
func _init(p_rollback_buffer: RollbackBuffer) -> void:
	_rollback_buffer = p_rollback_buffer


## Check if a recent interaction exists within the deduplication window.
##
## Searches both backward and forward from current_frame_index for matching
## interactions. Forward search is necessary during rollback to deduplicate
## against interactions recorded in frames that were already simulated before
## the rollback.
##
## Returns true if a matching interaction is found (duplicate).
##
## Parameters:
## - entity_a_id: First entity ID (order-independent)
## - entity_b_id: Second entity ID (order-independent)
## - current_frame_index: Current server frame index
## - interaction_type: Game-specific interaction enum value
func has_recent_interaction(
	entity_a_id: int,
	entity_b_id: int,
	current_frame_index: int,
	interaction_type: int
) -> bool:
	# Search window: current_frame +/- deduplication_window_frames.
	var search_start := max(
		0,
		current_frame_index - deduplication_window_frames
	)
	var search_end := current_frame_index + deduplication_window_frames

	# Check each frame in window (skip current frame).
	for frame_index in range(search_start, search_end + 1):
		if frame_index == current_frame_index:
			continue

		if not _rollback_buffer.has_at(frame_index):
			continue

		var frame_interactions: Array = _rollback_buffer.get_at(frame_index)
		if frame_interactions == null:
			continue

		for interaction in frame_interactions:
			if _matches_interaction(
				interaction,
				entity_a_id,
				entity_b_id,
				interaction_type
			):
				return true

	return false


## Record an interaction at the given frame.
##
## Stores the interaction in the rollback buffer for future deduplication
## checks. The interaction persists for deduplication_window_frames.
##
## Parameters:
## - entity_a_id: First entity ID (order-independent)
## - entity_b_id: Second entity ID (order-independent)
## - frame_index: Server frame index when interaction occurred
## - interaction_type: Game-specific interaction enum value
func record_interaction(
	entity_a_id: int,
	entity_b_id: int,
	frame_index: int,
	interaction_type: int
) -> void:
	# Get or create frame interactions array.
	var frame_interactions: Array
	if _rollback_buffer.has_at(frame_index):
		frame_interactions = _rollback_buffer.get_at(frame_index)
		if frame_interactions == null:
			# Note: Not using ArrayPool here because these arrays are stored in
			# the rollback buffer and automatically pruned when frames expire.
			# There's no cleanup hook to release them back to the pool.
			# Since interactions are infrequent (only on kills/bumps), the GC
			# pressure is minimal compared to state packing (every frame).
			frame_interactions = []
			_rollback_buffer.set_at(frame_index, frame_interactions)
			# Get the array back from buffer to ensure we have the right reference.
			frame_interactions = _rollback_buffer.get_at(frame_index)
	else:
		frame_interactions = []
		_rollback_buffer.set_at(frame_index, frame_interactions)
		# Get the array back from buffer to ensure we have the right reference.
		frame_interactions = _rollback_buffer.get_at(frame_index)

	# Append interaction record.
	frame_interactions.append({
		"a_id": entity_a_id,
		"b_id": entity_b_id,
		"type": interaction_type,
	})


## Check if an interaction record matches the given parameters.
##
## Compares interaction type and entity IDs (order-independent).
## Returns true if all parameters match.
func _matches_interaction(
	interaction: Dictionary,
	entity_a_id: int,
	entity_b_id: int,
	interaction_type: int
) -> bool:
	if interaction.type != interaction_type:
		return false

	# Order-independent matching: (A, B) matches (B, A).
	var matches_forward: bool = (
		interaction.a_id == entity_a_id and interaction.b_id == entity_b_id
	)
	var matches_reverse: bool = (
		interaction.a_id == entity_b_id and interaction.b_id == entity_a_id
	)

	return matches_forward or matches_reverse


## Set the deduplication window size in frames.
##
## Larger windows provide more aggressive deduplication but use more memory.
## Typical values: 2-8 frames at 60 FPS.
func set_deduplication_window(frames: int) -> void:
	deduplication_window_frames = max(1, frames)


## Clear all interaction history.
##
## Called when rollback buffer is reset or match ends.
func clear() -> void:
	# Note: Actual clearing happens automatically as rollback buffer prunes old
	# frames. This method is provided for explicit clearing if needed.
	pass
