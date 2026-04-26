extends Node
## Global Netcode singleton for simple_game example.
##
## Provides global access to the NetworkOrchestrator instance. This singleton
## is required by ReconcilableState and other plugin components.

var orchestrator: NetworkOrchestrator

# Convenience accessors that delegate to orchestrator.
var is_server: bool:
	get:
		return orchestrator.is_server if orchestrator else false

var is_client: bool:
	get:
		return orchestrator.is_client if orchestrator else true

var server_frame_index: int:
	get:
		return orchestrator.server_frame_index if orchestrator else 0

var frame_driver: FrameDriver:
	get:
		return orchestrator.frame_driver if orchestrator else null

var logger: NetworkLogger:
	get:
		return orchestrator.logger if orchestrator else null


func initialize(
	p_orchestrator: NetworkOrchestrator
) -> void:
	orchestrator = p_orchestrator


func get_peer_id_from_player_id(player_id: int) -> int:
	return orchestrator.get_peer_id_from_player_id(player_id)


func get_local_player_index_from_player_id(player_id: int) -> int:
	return orchestrator.get_local_player_index_from_player_id(player_id)
