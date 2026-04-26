class_name GameSettings
extends NetworkSettings
## Example NetworkSettings implementation for simple_game.
##
## Sets reasonable defaults for a basic multiplayer game with up to 4 players
## and 1.5 seconds of rollback buffer (90 frames at 60 FPS).


func _init() -> void:
	# Network settings.
	server_port = 4433
	max_client_count = 4
	rollback_buffer_duration_sec = 1.5

	# Disable pause for simplicity.
	is_server_pause_enabled = false

	# Debug settings.
	tracking_perf = false
