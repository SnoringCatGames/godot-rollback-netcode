extends Node2D
## Main scene orchestrator for simple_game rollback netcode example.
##
## Handles:
## - Plugin initialization with dependency injection
## - Server/client mode detection from command-line args
## - Player spawning via MultiplayerSpawner
## - Connection management.

const PLAYER_SCENE := preload("res://addons/rollback_netcode/examples/simple_game/scenes/player.tscn")

@onready var _spawner: MultiplayerSpawner = $MultiplayerSpawner

var _orchestrator: NetworkOrchestrator
var _players := {} # Dictionary<int, CharacterBody2D>


func _ready() -> void:
	# Initialize rollback netcode plugin with dependencies.
	var config := GameSettings.new()
	var logger := GameLogger.new()
	var time := GameTime.new(get_tree())

	# Create and add NetworkOrchestrator.
	_orchestrator = NetworkOrchestrator.new(config, logger, time)
	_orchestrator.name = "NetworkOrchestrator"
	add_child(_orchestrator)

	# Register orchestrator with global singleton.
	Netcode.initialize(_orchestrator)

	# Connect spawner signals.
	_spawner.spawned.connect(_on_player_spawned)

	# Connect multiplayer signals.
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)

	# Wait for orchestrator to initialize, then start server/client.
	await get_tree().process_frame

	# Start server or client based on orchestrator's role detection.
	if _orchestrator.is_server:
		_start_server()
	else:
		_start_client()


func _start_server() -> void:
	print("[MAIN] Starting server on port %d..." % _orchestrator.server_port)
	_orchestrator.connector.server_enable_connections(
		_orchestrator.server_port
	)

	# Spawn player for server (peer ID 1).
	_spawn_player(1)


func _start_client() -> void:
	print("[MAIN] Connecting to server at 127.0.0.1:%d..." % _orchestrator.server_port)
	_orchestrator.connector.client_connect_to_server(
		"127.0.0.1",
		_orchestrator.server_port
	)


func _on_peer_connected(peer_id: int) -> void:
	print("[MAIN] Peer connected: %d" % peer_id)

	# Server spawns player for new client.
	if multiplayer.is_server():
		_spawn_player(peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	print("[MAIN] Peer disconnected: %d" % peer_id)

	# Remove player.
	if _players.has(peer_id):
		_players[peer_id].queue_free()
		_players.erase(peer_id)


func _spawn_player(peer_id: int) -> void:
	if _players.has(peer_id):
		return # Already spawned.

	var player := PLAYER_SCENE.instantiate()
	player.name = "Player_%d" % peer_id

	# Set random spawn position.
	var spawn_radius := 200.0
	var angle := randf() * TAU
	player.position = Vector2(cos(angle), sin(angle)) * spawn_radius

	# Set random color for visual distinction.
	var color_rect: ColorRect = player.get_node("ColorRect")
	color_rect.color = Color.from_hsv(randf(), 0.7, 0.9)

	# Set player_id on PlayerState.
	# For simplicity in this example, we use peer_id as player_id directly.
	var player_state: PlayerState = player.get_node("PlayerState")
	player_state.player_id = peer_id

	# Register the player_id -> peer_id mapping in NetworkConnector.
	# This is required for ReconcilableState to determine multiplayer authority.
	_orchestrator.connector.register_player_state(peer_id, peer_id, 0)

	# Add to scene.
	add_child(player, true)
	_players[peer_id] = player

	print("[MAIN] Spawned player for peer %d" % peer_id)


func _on_player_spawned(node: Node) -> void:
	print("[MAIN] Player spawned: %s" % node.name)
