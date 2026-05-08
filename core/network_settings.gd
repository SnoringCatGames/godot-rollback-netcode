class_name NetworkSettings
extends Resource
## Configuration for rollback netcode plugin.
##
## This allows users to edit network settings via Godot's Inspector panel. Users
## can create a .tres file or subclass this Resource to customize network
## behavior.
##
## Usage:
## 1. Create a .tres file: Right-click in FileSystem > New Resource >
##    NetworkSettings
## 2. Edit properties in Inspector panel
## 3. Load in code: var config := load("res://network_settings.tres")
##
## Or subclass for custom logic:
## ```gdscript
## class_name MyGameSettings
## extends NetworkSettings
##
## @export var custom_setting := true
## ```


## Transport protocol for multiplayer connections.
enum TransportType {
	ENET,      ## UDP-based. Native desktop clients.
	WEBSOCKET, ## TCP-based. Web and mobile clients.
	WEBRTC,    ## UDP-like DataChannel. Web cross-play.
}


## Network settings.
## Transport protocol used for server and client peers.
@export var transport_type := TransportType.ENET

## Port number for server to listen on / client to connect to.
@export var server_port := 4433

## Port for the WebRTC signaling WebSocket. Only used when
## transport_type == WEBRTC. Defaults to 0, which means "use
## server_port" (the legacy GameLift-era behavior). Set to a
## different value when the deploy environment binds signaling
## and game data to separate container ports — Edgegap declares
## 4433/UDP and 4434/TCP and forwards them to host ports
## independently, so on Edgegap this should be 4434.
@export var signaling_port: int = 0

## Server-only. The external host UDP port that the deploy
## platform mapped to the game-data container port. Used by
## WebRTCSignalingServer to rewrite the server's STUN-reflected
## ICE candidate (port-preserving NAT means the srflx candidate
## advertises the container port, not the host port the client
## must dial). Defaults to 0; set from the deploy env at boot
## (Edgegap: ARBITRIUM_PORT_GAME_EXTERNAL; GameLift: gamePort).
@export var host_udp_port: int = 0

## TLS options for the WebSocket server. When set, the
## server uses WSS (TLS-encrypted WebSocket) instead of
## plain WS. Leave null for unencrypted connections
## (preview/local mode).
var server_tls_options: TLSOptions

## Maximum number of simultaneous client connections.
@export var max_client_count := 4

## Target network tick rate in frames per second.
## This determines the simulation frequency for networked game state.
## Common values: 30 (lower bandwidth), 60 (standard), 120 (high precision).
@export var target_network_fps := 60.0

## Physics tick rate override for WebRTC matches.
## 0 = use target_network_fps (no override). Lower
## values reduce CPU load for WASM web clients at
## the cost of coarser physics steps. Both server
## and client must agree.
@export var webrtc_physics_fps := 30.0

## Target send rate for replicated state (Hz).
## 0 = same as target_network_fps. Only affects
## predicted state sends. Input and confirmed
## authoritative state are unaffected. Use integer
## divisors of target_network_fps for even spacing
## (e.g., 30, 20, 15 for 60 Hz sim).
@export var target_state_send_fps := 0.0

## Per-transport send rate overrides (Hz). 0 = use
## target_state_send_fps. Only effective on the
## server.
@export var enet_state_send_fps := 30.0
@export var websocket_state_send_fps := 20.0
@export var webrtc_state_send_fps := 20.0

## Duration of rollback buffer in seconds.
@export var rollback_buffer_duration_sec := 1.5


## Pause settings.
## Whether server-initiated pause is enabled.
@export var is_server_pause_enabled := false

## Maximum number of pause requests per client (if pause is enabled).
@export var max_pauses_per_client := 1

## Cooldown between pause requests in seconds.
@export var pause_request_cooldown_sec := 30.0

## Maximum pause duration before auto-unpause (seconds).
@export var max_pause_duration_sec := 60.0


## Match start countdown duration in seconds.
## Countdown dynamically displays numbers based on duration (e.g., 4, 3, 2, 1, GO
## for a 4-second countdown), then match begins when GO appears.
@export var match_start_countdown_sec := 3.0


## Input delay settings.
## Whether adaptive input delay is enabled (adjusts based on RTT).
## When enabled, local input is delayed by a calculated number of frames
## so the server receives it before it needs to simulate that frame.
@export var is_adaptive_input_delay_enabled := true

## Maximum input delay in frames. Adaptive delay will not exceed this.
## At 60 FPS: 8 frames = ~133ms. 0 = input delay disabled entirely.
@export var max_input_delay_frames := 8


## Redundant input settings.
## Number of recent input frames to include in each state packet.
## Higher values tolerate more packet loss but increase packet size
## slightly. 0 = disabled.
@export var redundant_input_frame_count := 3


## Preview mode (local multi-instance testing).
## Whether running in local preview mode (multiple instances in editor).
var is_preview_mode := false

## Whether to run multiple client instances in preview mode.
@export var preview_run_multiple_clients := false

## Expected number of clients in preview mode.
var preview_client_count: int:
	get:
		return 2 if preview_run_multiple_clients else 1

## Whether to connect to remote server in preview mode (false = local only).
@export var preview_connect_to_remote_server := false

## Local server IP for preview mode.
@export var local_preview_server_ip_address := &"127.0.0.1"


## Player settings.
## Maximum number of local players per client (split-screen/couch co-op).
@export var max_local_player_count := 4


## Debug/performance tracking.
## Whether to enable perf logging.
@export var tracking_perf := true

## Whether to include verbose/debug logs in output.
## When disabled, verbose() calls are skipped (no string manipulation overhead).
@export var includes_verbose_logs := false

@export var includes_frame_index_in_logs := true


## Network condition simulation (dev/debug only).
## These settings have no effect in release builds.
@export_group("Network Simulation (Dev Only)")

## Master enable for network condition simulation.
## When enabled, delays are applied to both incoming and outgoing
## states symmetrically (simulating real round-trip latency).
@export var network_sim_enabled := false

## Artificial one-way latency in milliseconds.
@export var network_sim_latency_ms := 0

## Jitter: random variation added to latency (+/- this value in ms).
@export var network_sim_jitter_ms := 0

## Percentage of incoming states to drop (0-100).
@export var network_sim_packet_loss_pct := 0.0

## Artificial delay per physics tick in milliseconds (slows frame
## processing to simulate a struggling machine).
@export var network_sim_frame_delay_ms := 0

## Max state deliveries per second (0 = unlimited).
@export var network_sim_bandwidth_limit := 0

## Spike pattern: interval between latency spikes (0 = disabled).
@export var network_sim_spike_interval_sec := 0.0

## Duration of each latency spike in milliseconds.
@export var network_sim_spike_duration_ms := 0

## Latency during a spike in milliseconds.
@export var network_sim_spike_latency_ms := 0

@export_group("")
