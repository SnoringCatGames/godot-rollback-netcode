extends CharacterBody2D
## Simple player character for rollback netcode example.
##
## Handles WASD movement in _network_process (called via PlayerState). Movement
## is server-authoritative with client-side prediction and rollback
## reconciliation.

const SPEED := 200.0

@onready var _player_state: PlayerState = $PlayerState


func _ready() -> void:
	# Deferred initialization of rollback buffer state.
	_player_state.record_initial_state.call_deferred()

	# Connect to network_process signal.
	_player_state.network_processed.connect(_on_network_process)


func _on_network_process() -> void:
	# Only process input if this is the local player.
	if not _player_state.is_multiplayer_authority():
		return

	# Get input direction.
	var input_direction := Vector2(
		Input.get_axis("ui_left", "ui_right"),
		Input.get_axis("ui_up", "ui_down")
	).normalized()

	# Update velocity.
	velocity = input_direction * SPEED

	# Move the character.
	move_and_slide()
