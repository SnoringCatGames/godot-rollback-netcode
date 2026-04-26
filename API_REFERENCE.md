# Rollback Netcode API Reference

# FIXME: REVIEW

Comprehensive class-by-class API documentation for the rollback netcode plugin.

---

## Table of Contents

### Core Classes
- [NetworkOrchestrator](#networkorchestrator)
- [NetworkConnector](#networkconnector)
- [FrameDriver](#framedriver)
- [FrameSynchronizer](#framesynchronizer)
- [FrameProcessor](#frameprocessor)
- [ReconcilableState](#reconcilablestate)
- [NetworkSettings](#NetworkSettings)

### Interfaces
- [NetworkLogger](#networklogger)
- [NetworkTime](#networktime)

### State Management
- [ClientSession](#clientsession)
- [MatchState](#matchstate)
- [PlayerState](#playerstate)
- [InteractionTracker](#interactiontracker)

### Utilities
- [CircularBuffer](#circularbuffer)
- [ArrayPool](#arraypool)
- [RollbackBuffer](#rollbackbuffer)
- [PerfTracker](#perftracker)
- [FrameAuthority](#frameauthority)

---

# Core Classes

## NetworkOrchestrator

**File:** `core/network_orchestrator.gd`
**Extends:** Node

Central orchestrator for the rollback netcode plugin. Manages and provides access to core networking subsystems and determines the local machine's role (server vs client).

### Properties

| Name | Type | Description |
|------|------|-------------|
| config | NetworkSettings | Configuration resource injected during initialization |
| logger | NetworkLogger | Logger for diagnostic messages |
| time_provider | NetworkTime | Time provider for timers and throttling |
| connector | NetworkConnector | ENet peer management and connection lifecycle |
| frame_driver | Node | Frame-synchronous simulation (FrameDriver instance) |
| frame_sync | FrameSynchronizer | NTP-like frame index synchronization |
| perf_tracker | PerfTracker | Optional performance tracker for metrics |
| is_preview | bool | Whether running in preview mode (editor multi-instance) |
| is_headless | bool | Whether running in headless mode |
| is_server | bool | True if this machine is the server |
| is_client | bool | True if this machine is a client |
| is_primary_client | bool | True if first client in preview mode, or any client in published mode |
| preview_client_number | int | Client number in preview mode (1, 2, 3...) |
| should_connect_to_remote_server | bool | Whether to connect to remote server in preview mode |
| server_port | int | Server port (from --port arg or config) |
| is_connected_to_server | bool | Connection status (always true on server) |
| local_peer_id | int | Local multiplayer peer ID |
| server_frame_index | int | Current server frame index |

### Methods

#### _init(p_config: NetworkSettings, p_logger: NetworkLogger, p_time: NetworkTime) -> void

Constructor. Initializes orchestrator with required dependencies.

**Parameters:**
- `p_config` (NetworkSettings): Configuration resource
- `p_logger` (NetworkLogger): Logger implementation
- `p_time` (NetworkTime): Time provider implementation

**Example:**
```gdscript
var orchestrator = NetworkOrchestrator.new(config, logger, time_provider)
add_child(orchestrator)
```

#### get_peer_id_from_player_id(p_player_id: int) -> int

Gets the peer_id associated with a given player_id.

**Parameters:**
- `p_player_id` (int): Player ID to look up

**Returns:** int - Peer ID, or 0 if not found

#### get_local_player_index_from_player_id(p_player_id: int) -> int

Gets the local player index for a given player_id (0, 1, 2... for split-screen).

**Parameters:**
- `p_player_id` (int): Player ID to look up

**Returns:** int - Local player index, or -1 if not found

### Usage Example

```gdscript
# Create orchestrator (usually done in autoload singleton)
var config := load("res://network_settings.tres")
var logger := MyGameLogger.new()
var time := MyGameTime.new()

var orchestrator = NetworkOrchestrator.new(config, logger, time)
add_child(orchestrator)

# Access subsystems
if orchestrator.is_server:
    orchestrator.connector.server_enable_connections(orchestrator.server_port)
else:
    orchestrator.connector.client_connect_to_server("127.0.0.1", 4433)

# Access current frame
var current_frame = orchestrator.server_frame_index
```

### Notes

- Determines server/client role from command-line arguments or headless mode
- Automatically initializes subsystems in `_enter_tree()`
- Testing with multiple instances: Use `--server`, `--client=1`, `--client=2` launch arguments
- Reads `--port` command-line argument to override config server port

---

## NetworkConnector

**File:** `core/network_connector.gd`
**Extends:** Node

Manages ENet multiplayer peer connections between server and clients. Handles peer lifecycle, player declaration, and version validation.

### Properties

| Name | Type | Description |
|------|------|-------------|
| config | NetworkSettings | Configuration resource |
| logger | NetworkLogger | Logger for diagnostic messages |
| orchestrator | Node | Reference to NetworkOrchestrator |
| player_attribute_validator | Callable | Game-specific player attribute validation function |
| client_session_provider | Callable | Provider for local session data (player count, IDs, attributes) |
| is_connected_to_server | bool | Client connection status |
| is_server | bool | True if server |
| is_client | bool | True if client |
| last_disconnect_reason | DisconnectReason | Reason for last disconnection |

### Signals

#### peer_players_declared(peer_id: int, assigned_ids: Array[int], player_attributes: Array)

Emitted when a peer declares their player count and receives assigned IDs from server.

#### connected(local_peer_id: int)

Emitted when client successfully connects to server.

#### disconnected(peer_id: int, reason: int)

Emitted when disconnection occurs (client or server).

#### player_ids_assigned(assigned_ids: Array[int])

Emitted when client receives assigned player IDs from server.

### Enums

#### DisconnectReason

| Value | Description |
|-------|-------------|
| UNKNOWN | Unknown disconnect reason |
| CLIENT_INITIATED | Client explicitly disconnected |
| SERVER_SHUTDOWN | Server shut down gracefully |
| CONNECTION_LOST | Connection lost unexpectedly |

### Methods

#### server_enable_connections(p_server_port: int) -> void

[Server] Start accepting client connections.

**Parameters:**
- `p_server_port` (int): Port to bind to

**Example:**
```gdscript
connector.server_enable_connections(4433)
```

#### client_connect_to_server(p_server_ip_address: String, p_server_port: int) -> void

[Client] Connect to a remote server.

**Parameters:**
- `p_server_ip_address` (String): Server IP address
- `p_server_port` (int): Server port

**Example:**
```gdscript
connector.client_connect_to_server("127.0.0.1", 4433)
```

#### server_close_multiplayer_session() -> void

[Server] Gracefully close all client connections.

#### client_disconnect() -> void

[Client] Disconnect from server.

#### server_register_player_id_to_peer_mapping(p_player_id: int, p_peer_id: int) -> void

[Server] Register player_id to peer_id mapping.

**Parameters:**
- `p_player_id` (int): Player ID
- `p_peer_id` (int): Peer ID

#### client_on_player_state_connected(p_player_id: int, p_peer_id: int, p_local_index: int) -> void

[Client] Register player state connection.

**Parameters:**
- `p_player_id` (int): Player ID
- `p_peer_id` (int): Peer ID
- `p_local_index` (int): Local player index

#### get_peer_id_from_player_id(p_player_id: int) -> int

Gets the peer_id associated with a given player_id.

**Returns:** int - Peer ID, or 0 if not found

#### get_local_player_index_from_player_id(p_player_id: int) -> int

Gets the local player index for a given player_id.

**Returns:** int - Local player index, or -1 if not found

### Usage Example

```gdscript
# Setup local session provider
connector.client_session_provider = func() -> Dictionary:
    return {
        "session_ids": [1, 2],
        "player_count": 2,
        "attributes": [
            {"name": "Player1", "color": "red"},
            {"name": "Player2", "color": "blue"}
        ]
    }

# Setup player attribute validator
connector.player_attribute_validator = func(
    attributes: Array,
    expected_count: int,
    peer_id: int
) -> Array:
    # Validate and sanitize attributes
    return attributes.slice(0, expected_count)

# Connect signals
connector.peer_players_declared.connect(_on_players_declared)
connector.connected.connect(_on_connected)
connector.disconnected.connect(_on_disconnected)
```

### Notes

- Automatically validates client version against server version
- Sends player declaration to server on connection
- Server assigns sequential player IDs starting from 1
- Version validation uses semantic versioning from ProjectSettings
- RPC channels defined as constants: RPC_CHANNEL_DEFAULT (0), RPC_CHANNEL_SESSION_CONTROL (1), RPC_CHANNEL_CLOCK_SYNC (2), RPC_CHANNEL_GAME_EVENTS (3), RPC_CHANNEL_STATS (4), RPC_CHANNEL_DEBUG (5)

---

## FrameDriver

**File:** `core/frame_driver.gd`
**Extends:** Node

Core frame-synchronous simulation engine for client-prediction rollback networking. Manages deterministic frame-based simulation at fixed 60 FPS.

### Properties

| Name | Type | Description |
|------|------|-------------|
| config | NetworkSettings | Configuration resource |
| logger | NetworkLogger | Logger for diagnostic messages |
| time_provider | NetworkTime | Time provider for timers |
| orchestrator | Node | Reference to NetworkOrchestrator |
| connector | Node | Reference to NetworkConnector |
| server_frame_index | int | Current frame index (incremented on each physics tick) |
| is_paused | bool | Whether frame simulation is paused |
| pause_start_frame | int | Frame index when pause started (0 if not paused) |
| rollback_buffer_size | int | Number of frames stored in rollback buffer |
| oldest_rollbackable_frame_index | int | Oldest frame that can be rolled back to |
| last_rollback_frame_count | int | Number of frames in last rollback |
| last_rollback_duration_usec | int | Duration of last rollback (microseconds) |
| total_rollbacks | int | Total number of rollbacks |
| last_fastforward_frame_count | int | Number of frames in last fast-forward |
| last_fastforward_duration_usec | int | Duration of last fast-forward (microseconds) |
| total_fastforwards | int | Total number of fast-forwards |

### Constants

| Name | Value | Description |
|------|-------|-------------|
| TARGET_NETWORK_FPS | 60 | Target network frame rate |
| TARGET_NETWORK_TIME_STEP_SEC | 1/60 | Time step per frame (seconds) |
| TARGET_NETWORK_TIME_STEP_USEC | 16666 | Time step per frame (microseconds) |

### Signals

#### pause_state_changed(is_paused: bool, initiator_peer_id: int)

Emitted when pause state changes.

#### pause_requested(peer_id: int)

Emitted when a pause is requested (for validation).

#### unpause_requested(peer_id: int)

Emitted when an unpause is requested.

### Methods

#### add_networked_state(node: ReconcilableState) -> void

Registers a ReconcilableState node for frame-synchronous processing.

**Parameters:**
- `node` (ReconcilableState): Node to register

#### remove_networked_state(node: ReconcilableState) -> void

Unregisters a ReconcilableState node.

**Parameters:**
- `node` (ReconcilableState): Node to unregister

#### add_frame_processor(node: FrameProcessor) -> void

Registers a FrameProcessor node for frame processing.

**Parameters:**
- `node` (FrameProcessor): Node to register

#### remove_frame_processor(node: FrameProcessor) -> void

Unregisters a FrameProcessor node.

**Parameters:**
- `node` (FrameProcessor): Node to unregister

#### queue_rollback(p_conflicting_frame_index: int) -> bool

Schedules a rollback to occur on the next network process.

**Parameters:**
- `p_conflicting_frame_index` (int): Frame where mismatch occurred

**Returns:** bool - True if rollback scheduled, false if frame too old

**Example:**
```gdscript
if state_mismatch_detected:
    frame_driver.queue_rollback(mismatch_frame_index)
```

#### is_frame_too_old_to_consider(p_frame_index: int) -> bool

Checks if a frame is too old to rollback to.

**Parameters:**
- `p_frame_index` (int): Frame index to check

**Returns:** bool - True if frame is outside rollback buffer range

#### server_set_is_paused(paused: bool) -> void

[Server] Pause or unpause frame simulation.

**Parameters:**
- `paused` (bool): True to pause, false to unpause

**Example:**
```gdscript
# Pause game while waiting for players
frame_driver.server_set_is_paused(true)

# Unpause when ready
frame_driver.server_set_is_paused(false)
```

#### client_request_toggle_pause() -> void

[Client] Request toggle of pause state.

#### client_request_pause() -> void

[Client] Request pause (if enabled in config).

#### client_request_unpause() -> void

[Client] Request unpause (if enabled in config).

#### fast_forward(new_frame_index: int) -> void

Fast-forward simulation to catch up to server.

**Parameters:**
- `new_frame_index` (int): Target frame index

### Frame Processing Cycle

The three-phase processing cycle called by FrameDriver:

1. **_pre_network_process()**: Restore state from rollback buffer
2. **_network_process()**: Execute game logic
3. **_post_network_process()**: Pack and record new state

### Usage Example

```gdscript
# Access via singleton
var current_frame = Netcode.server_frame_index

# Queue rollback on mismatch
if prediction_mismatch:
    Netcode.frame_driver.queue_rollback(mismatch_frame)

# Check rollback metrics
if Netcode.frame_driver.total_rollbacks > 100:
    print("High rollback count - check network quality")
```

### Notes

- Increments `server_frame_index` directly on each physics tick
- Starts paused by default - server unpauses when ready
- Rollback buffer size is configurable (default 1.5 seconds = ~90 frames)
- Only one rollback occurs per network process (earliest frame wins)
- Re-simulates frames during rollback without visual updates
- Fast-forward used when client falls behind server

---

## FrameSynchronizer

**File:** `core/frame_synchronizer.gd`
**Extends:** Node

Synchronizes frame indices between server and clients using NTP-like protocol combined with frame broadcasts.

### Properties

| Name | Type | Description |
|------|------|-------------|
| logger | NetworkLogger | Logger for diagnostic messages |
| frame_driver | Node | Reference to FrameDriver |
| connector | Node | Reference to NetworkConnector |
| rtt_usec | float | Smoothed round-trip time (microseconds) |

### Constants

| Name | Value | Description |
|------|-------|-------------|
| DRIFT_THRESHOLD_FRAMES | 1 | Correct drift if +/- this many frames off |
| PING_INTERVAL_SEC | 3.0 | Ping server every N seconds |
| RTT_SMOOTHING_FACTOR | 0.2 | Exponential moving average weight |
| TARGET_NETWORK_TIME_STEP_SEC | 1/60 | 60 FPS frame timing |

### Methods

The FrameSynchronizer operates automatically via internal RPC methods. No public API is exposed beyond construction.

### Usage Example

```gdscript
# Created automatically by NetworkOrchestrator
var frame_sync = FrameSynchronizer.new(logger, frame_driver, connector)
add_child(frame_sync)

# Access RTT for performance metrics
var ping_ms = frame_sync.rtt_usec / 1000.0
```

### NTP + Frame Sync Protocol

1. Client sends ping with timestamp (t1) every 3 seconds
2. Server receives ping at t2, sends pong with:
   - t1 (client send time)
   - t2 (server receive time)
   - t3 (server send time)
   - current_frame (server frame index at t3)
3. Client receives pong at t4
4. Client calculates RTT = (t4 - t1) - (t3 - t2)
5. Client estimates current server frame and corrects drift if needed

### Notes

- Automatically corrects frame drift beyond threshold
- Uses exponential moving average for RTT smoothing
- Fast-forwards client if behind server
- Hard resets client if ahead of server (shouldn't happen normally)
- Runs continuously in _process() on clients

---

## FrameProcessor

**File:** `core/frame_processor.gd`
**Extends:** Node
**@tool**

Helper node that enables any node to participate in frame-synchronous network processing without full rollback support.

### Properties

| Name | Type | Description |
|------|------|-------------|
| root_path | NodePath | Path to the node that implements _network_process() |
| root | Node | Cached reference to the root node |

### Methods

#### _network_process() -> void

Called by FrameDriver during network frame processing. Delegates to root node's _network_process() method.

### Usage Example

```gdscript
# Scene tree:
# MyGameNode (has _network_process method)
#   ├── FrameProcessor (root_path = "..")
#   └── Sprite2D

# MyGameNode.gd
extends Node

func _network_process() -> void:
    # Update UI, play audio, etc.
    # This runs during network frame processing
    $Sprite2D.position = some_networked_state.position
```

### Notes

- Use for nodes that need frame-sync processing without rollback
- Typical use cases: UI updates, visual effects, audio triggers
- Auto-populates root_path to owner when placed in editor
- Shows configuration warnings if root_path invalid or _network_process() missing
- Automatically registered/deregistered with FrameDriver

---

## ReconcilableState

**File:** `core/reconcilable_state.gd`
**Extends:** MultiplayerSynchronizer
**@tool**

**This is the most important class in the plugin.** Base class for all networked entities requiring client-side prediction with server-mismatch reconciliation and rollback support.

### Properties

| Name | Type | Description |
|------|------|-------------|
| frame_index | int | Estimated server frame when this state occurred |
| frame_authority | FrameAuthority | Authority level (AUTHORITATIVE, SERVER_PREDICTED, or CLIENT_PREDICTED) |
| is_server_authoritative | bool | True if server is source of truth |
| is_client_authoritative | bool | True if client is source of truth |
| packed_state | Array | State packed for network replication |
| player_id | int | Server-assigned unique player ID |
| peer_id | int | Peer ID that owns this entity |
| local_player_index | int | Local player index (0, 1, 2...) |
| authority_id | int | Multiplayer authority ID |
| root | Node | Reference to root node (via root_path) |
| state_from_server | CharacterStateFromServer | Server-authoritative physics state (sibling) |
| input_from_client | PlayerInputFromClient | Client-authoritative input (sibling) |
| forwarded_input_from_server | ForwardedPlayerInputFromServer | Server-forwarded remote input (sibling) |
| last_interaction_type | int | Last interaction type (game-specific enum) |
| last_interaction_frame_index | int | Frame when interaction occurred |
| last_interaction_position | Vector2 | Position of interaction |
| last_interaction_velocity | Vector2 | Bounce velocity of interaction |

### Enums

#### FrameAuthority

| Value | Description |
|-------|-------------|
| UNKNOWN | Authority not yet determined |
| AUTHORITATIVE | Server has real input, state is authoritative |
| SERVER_PREDICTED | Server guessing input (extrapolating), lower confidence |
| CLIENT_PREDICTED | Client has real input, predicting outcome |

### Signals

#### received_network_state

Emitted when networked state is received from authority.

#### network_processed

Emitted after _network_process() completes.

#### player_id_changed(new_player_id: int)

Emitted when player_id changes.

### Abstract Methods (Must Override)

#### _get_is_server_authoritative() -> bool

Returns true if server is authoritative source for this state.

**Example:**
```gdscript
func _get_is_server_authoritative() -> bool:
    return true  # Server-authoritative character physics
```

#### _has_non_rollbackable_interactions() -> bool

Returns true if this class uses the interaction tracking system.

**Example:**
```gdscript
func _has_non_rollbackable_interactions() -> bool:
    return true  # Track kills/deaths
```

#### _is_interaction_rollbackable(interaction_type: int) -> bool

Returns true if interaction can be recalculated during rollback.

**Example:**
```gdscript
func _is_interaction_rollbackable(interaction_type: int) -> bool:
    return interaction_type != InteractionType.KILLED
```

#### _get_default_values() -> Array

Returns initial state values for all synced properties.

**Example:**
```gdscript
func _get_default_values() -> Array:
    return [Vector2.ZERO, Vector2.ZERO, false]  # position, velocity, is_jumping
```

#### _sync_to_scene_state(previous_state: Array) -> void

Updates scene from networked properties. Called in _pre_network_process().

**Parameters:**
- `previous_state` (Array): Previous frame state for just_* comparisons

**Example:**
```gdscript
func _sync_to_scene_state(previous_state: Array) -> void:
    root.position = position
    root.velocity = velocity
```

#### _sync_from_scene_state() -> void

Updates networked properties from scene. Called in _post_network_process().

**Example:**
```gdscript
func _sync_from_scene_state() -> void:
    position = root.position
    velocity = root.velocity
```

#### _restore_indirect_interaction_state(frame_state: Array) -> void

Restores indirect scene state based on interaction type (collision layers, visibility).

**Example:**
```gdscript
func _restore_indirect_interaction_state(frame_state: Array) -> void:
    if last_interaction_type == InteractionType.DIED:
        root.visible = false
        root.collision_layer = 0
```

### Required Property Dictionary

Subclasses must define `_synced_properties_and_rollback_diff_thresholds`:

```gdscript
var _synced_properties_and_rollback_diff_thresholds := {
    "position": 1.0,        # Mismatch if distance > 1.0 pixel
    "velocity": 10.0,       # Mismatch if difference > 10.0 pixels/sec
    "is_jumping": 0,        # Exact match required (0 = no threshold)
}
```

### Methods

#### record_initial_state(include_partners := true) -> void

Records initial spawn state to rollback buffer. Call this (deferred) after _ready().

**Parameters:**
- `include_partners` (bool): Also record partner nodes (input/forwarded state)

**Example:**
```gdscript
func _ready() -> void:
    super._ready()
    call_deferred("record_initial_state")
```

#### update_authority() -> void

Updates multiplayer authority based on player_id and is_server_authoritative.

#### record_interaction(interaction_type: int, frame_index: int, position: Vector2, direction: Vector2) -> void

Records an interaction in rollback buffer.

**Parameters:**
- `interaction_type` (int): Game-specific enum value
- `frame_index` (int): Frame when interaction occurred (-1 = current frame)
- `position` (Vector2): Position of interaction
- `direction` (Vector2): Direction of interaction

**Example:**
```gdscript
record_interaction(
    InteractionType.KILLED,
    Netcode.server_frame_index,
    global_position,
    velocity.normalized()
)
```

### Complete Usage Example

```gdscript
@tool
class_name CharacterStateFromServer
extends ReconcilableState

var position := Vector2.ZERO
var velocity := Vector2.ZERO
var is_jumping := false

var _synced_properties_and_rollback_diff_thresholds := {
    "position": 1.0,
    "velocity": 10.0,
    "is_jumping": 0,
}

func _get_is_server_authoritative() -> bool:
    return true

func _has_non_rollbackable_interactions() -> bool:
    return false  # No interaction tracking for basic character

func _get_default_values() -> Array:
    return [Vector2.ZERO, Vector2.ZERO, false]

func _sync_to_scene_state(previous_state: Array) -> void:
    root.position = position
    root.velocity = velocity

func _sync_from_scene_state() -> void:
    position = root.position
    velocity = root.velocity

func _restore_indirect_interaction_state(_frame_state: Array) -> void:
    # No indirect state for basic character
    pass

func _ready() -> void:
    super._ready()
    call_deferred("record_initial_state")
```

### Notes

- **Must** be marked with @tool annotation
- Bridge between MultiplayerSynchronizer, RollbackBuffer, and FrameDriver
- Server-authoritative: Server is source of truth (position, health)
- Client-authoritative: Client is source of truth (input)
- Three-phase cycle: _pre_network_process → _network_process → _post_network_process
- Mismatch thresholds prevent rollback for tiny floating-point differences
- Non-rollbackable interactions (kills) are preserved during rollback
- Shows configuration warnings for missing properties or invalid setup

---

## NetworkSettings

**File:** `core/network_settings.gd`
**Extends:** Resource

Configuration resource for rollback netcode plugin. Users edit via Inspector or create .tres files.

### Properties

| Category | Name | Type | Default | Description |
|----------|------|------|---------|-------------|
| **Network** | server_port | int | 4433 | Port for server to bind/client to connect |
| | max_client_count | int | 4 | Maximum simultaneous client connections |
| | rollback_buffer_duration_sec | float | 1.5 | Duration of rollback buffer (seconds, ~90 frames at 60 FPS) |
| **Pause** | is_server_pause_enabled | bool | false | Whether server-initiated pause is enabled |
| | max_pauses_per_client | int | 1 | Maximum pause requests per client |
| | pause_request_cooldown_sec | float | 30.0 | Cooldown between pause requests |
| | max_pause_duration_sec | float | 60.0 | Max pause duration before auto-unpause |
| **Preview** | is_preview_mode | bool | false | Whether running in local preview mode |
| | preview_client_count | int | 2 | Expected number of clients in preview |
| | preview_connect_to_remote_server | bool | false | Connect to remote server in preview |
| **Players** | max_local_player_count | int | 4 | Maximum local players per client (split-screen) |
| **Debug** | tracking_perf | bool | false | Show performance tracker UI |

### Usage Example

```gdscript
# Create .tres file in editor:
# Right-click in FileSystem > New Resource > NetworkSettings
# Edit properties in Inspector
# Save as "res://network_settings.tres"

# Load in code:
var config := load("res://network_settings.tres") as NetworkSettings
var orchestrator = NetworkOrchestrator.new(config, logger, time)

# Or subclass for custom logic:
class_name MyGameSettings
extends NetworkSettings

@export var custom_setting := true
```

### Notes

- All properties are @export for Inspector editing
- Rollback buffer size calculated as: duration * 60 FPS
- Preview mode detected via OS.has_feature("editor")
- Server port can be overridden with --port command-line argument

---

# Interfaces

## NetworkLogger

**File:** `core/network_logger.gd`
**Extends:** RefCounted

Abstract logging interface. Users implement to integrate with their game's logging system.

### Constants

| Name | Description |
|------|-------------|
| CATEGORY_DEFAULT | Default log category |
| CATEGORY_NETWORK | Network-related logs |
| CATEGORY_SYNC | Frame sync and rollback logs |
| CATEGORY_CONNECTIONS | Connection/disconnection logs |
| CATEGORY_FRAME | Frame processing logs |

### Methods

#### verbose(message: String, category: StringName = CATEGORY_DEFAULT) -> void

Log a verbose/debug message for detailed debugging.

#### info(message: String, category: StringName = CATEGORY_DEFAULT) -> void

Log an informational message for general operations.

#### warning(message: String, category: StringName = CATEGORY_DEFAULT) -> void

Log a warning for non-fatal issues.

#### error(message: String, category: StringName = CATEGORY_DEFAULT) -> void

Log a recoverable error.

#### fatal(message: String, category: StringName = CATEGORY_DEFAULT) -> void

Log a fatal error and halt execution (asserts).

#### check(condition: bool, message: String) -> bool

Check condition and log error if false. Returns condition value.

#### ensure(condition: bool, message: String) -> bool

Ensure condition is true, log fatal error and assert if false. Returns condition value.

### Usage Example

```gdscript
class_name MyGameLogger
extends NetworkLogger

func verbose(message: String, category: StringName = CATEGORY_DEFAULT) -> void:
    if Settings.includes_verbose_logs:
        print("[VERBOSE][%s] %s" % [category, message])

func info(message: String, category: StringName = CATEGORY_DEFAULT) -> void:
    print("[INFO][%s] %s" % [category, message])

func warning(message: String, category: StringName = CATEGORY_DEFAULT) -> void:
    push_warning("[%s] %s" % [category, message])

func error(message: String, category: StringName = CATEGORY_DEFAULT) -> void:
    push_error("[%s] %s" % [category, message])

func fatal(message: String, category: StringName = CATEGORY_DEFAULT) -> void:
    push_error("[FATAL][%s] %s" % [category, message])
    assert(false, message)
```

### Notes

- Default implementation prints to console
- Use categories for filtering logs by system
- `check()` for runtime validation that shouldn't crash
- `ensure()` for critical invariants that must never fail
- `fatal()` asserts in debug builds for immediate feedback

---

## NetworkTime

**File:** `core/network_time.gd`
**Extends:** RefCounted

Abstract time/timer interface. Users implement to integrate with their game's timer system.

### Methods

#### set_timeout(callback: Callable, delay_sec: float) -> int

Schedule a callback to be called after a delay.

**Parameters:**
- `callback` (Callable): Function to call after delay
- `delay_sec` (float): Delay in seconds

**Returns:** int - Timeout ID (for cancellation)

#### set_interval(callback: Callable, interval_sec: float) -> int

Schedule a callback to be called repeatedly at an interval.

**Parameters:**
- `callback` (Callable): Function to call repeatedly
- `interval_sec` (float): Interval in seconds

**Returns:** int - Interval ID (for cancellation)

#### clear_timeout(id: int) -> void

Cancel a scheduled timeout or interval.

**Parameters:**
- `id` (int): Timeout/interval ID

#### throttle(callback: Callable, cooldown_sec: float) -> Callable

Create a throttled version of a callback (calls limited to once per cooldown).

**Parameters:**
- `callback` (Callable): Function to throttle
- `cooldown_sec` (float): Minimum time between calls

**Returns:** Callable - Throttled function

### Usage Example

```gdscript
class_name MyGameTime
extends NetworkTime

var _scene_tree: SceneTree
var _next_id := 1
var _active_timers := {}  # <int, SceneTreeTimer>
var _active_intervals := {}  # <int, Dictionary>

func _init(scene_tree: SceneTree) -> void:
    _scene_tree = scene_tree

func set_timeout(callback: Callable, delay_sec: float) -> int:
    var timer := _scene_tree.create_timer(delay_sec)
    var id := _next_id
    _next_id += 1
    _active_timers[id] = timer
    timer.timeout.connect(func():
        callback.call()
        _active_timers.erase(id)
    )
    return id

func set_interval(callback: Callable, interval_sec: float) -> int:
    var id := _next_id
    _next_id += 1

    var repeat_func := func():
        callback.call()
        if _active_intervals.has(id):
            var timer := _scene_tree.create_timer(interval_sec)
            timer.timeout.connect(repeat_func)
            _active_intervals[id].timer = timer

    _active_intervals[id] = {"callback": callback, "interval": interval_sec}
    repeat_func.call()
    return id

func clear_timeout(id: int) -> void:
    _active_timers.erase(id)
    _active_intervals.erase(id)
```

### Notes

- Default implementation does nothing (logs warnings)
- `throttle()` has default implementation using Time.get_ticks_msec()
- Use SceneTree.create_timer() for simple implementation
- Timers must be cancelled via clear_timeout() to prevent leaks

---

# State Management

## ClientSession

**File:** `state/client_session.gd`
**Extends:** RefCounted

Abstract base class for local session state management. Tracks client-side game lifecycle, local players, and session snapshots.

### Properties

| Name | Type | Description |
|------|------|-------------|
| is_game_active | bool | Whether game is currently in match |
| is_game_loading | bool | Whether game is loading/transitioning |
| local_player_count | int | Number of local players (computed from device configs) |
| local_player_ids | Array[int] | Player IDs assigned to local players |
| local_device_configs | Array | Device configurations (input mappings) |
| local_player_attributes | Array[Dictionary] | Per-player metadata (name, appearance, etc.) |
| latest_match_state | MatchState | Snapshot of last match state (for UI) |
| latest_local_device_configs | Array | Snapshot of last device configs |
| latest_local_player_ids | Array[int] | Snapshot of last player IDs |

### Methods

#### clear() -> void

Clear all session state (called on disconnect or new session).

#### clear_latest_state() -> void

Clear latest state snapshots.

#### copy_latest_state(match_state: MatchState) -> void

Copy current state to latest snapshots (preserves state after disconnect for UI).

**Parameters:**
- `match_state` (MatchState): Current match state to snapshot

### Usage Example

```gdscript
class_name MyClientSession
extends ClientSession

var matchmaking_token: String = ""
var lobby_id: String = ""
var backend_session_id: String = ""

func has_valid_session() -> bool:
    return not matchmaking_token.is_empty()

func clear() -> void:
    super.clear()
    matchmaking_token = ""
    lobby_id = ""
    backend_session_id = ""
```

### Notes

- Represents "my local client state", not "multiplayer match state"
- local_device_configs typically contains input device mapping info
- local_player_attributes contains game-specific metadata (name, appearance, loadout)
- Snapshots used to display scoreboard/stats after disconnect

---

## MatchState

**File:** `state/match_state.gd`
**Extends:** RefCounted

Abstract base class for match/game session state management. Tracks player roster, match timing, and network replication.

### Properties

| Name | Type | Description |
|------|------|-------------|
| players_by_id | Dictionary | Player roster (player_id -> PlayerState) |
| packed_players | Array | Packed player data for network replication |
| match_start_frame_index | int | Server frame when match started |
| match_duration_usec | int | Match duration (microseconds) |
| is_match_ended | bool | Whether match has ended |
| match_time_remaining_sec | float | Time remaining (computed) |
| is_match_time_expired | bool | Whether time has expired (computed) |

### Signals

#### player_joined(player_state: PlayerState)

Emitted when player joins match (server and clients).

#### player_left(player_state: PlayerState)

Emitted when player leaves match (server and clients).

#### match_ended

Emitted when match ends.

#### players_updated

Emitted when player roster changes (low-level).

### Abstract Methods

#### _create_player_state() -> PlayerState

Create a new empty player state instance. Override to return custom PlayerState subclass.

### Methods

#### server_add_player(player_state: PlayerState) -> void

[Server] Add player to match.

**Parameters:**
- `player_state` (PlayerState): Player to add

#### server_remove_player(player_id: int) -> void

[Server] Remove player from match.

**Parameters:**
- `player_id` (int): Player ID to remove

#### server_start_match_timer(start_frame_index: int) -> void

[Server] Start match timer.

**Parameters:**
- `start_frame_index` (int): Frame when match started

#### server_end_match() -> void

[Server] End the match.

#### get_player(player_id: int) -> PlayerState

Get player state by ID.

**Returns:** PlayerState - Player state, or null if not found

#### get_players_for_peer(peer_id: int) -> Array[PlayerState]

Get all players for a specific peer.

**Parameters:**
- `peer_id` (int): Peer ID

**Returns:** Array[PlayerState] - All players owned by peer

### Usage Example

```gdscript
class_name MyMatchState
extends MatchState

signal player_scored(player_id: int, points: int)

var scores := {}  # player_id -> int
var deaths := {}  # player_id -> int

func _create_player_state() -> PlayerState:
    return MyPlayerState.new()

func server_add_score(player_id: int, points: int) -> void:
    if not scores.has(player_id):
        scores[player_id] = 0
    scores[player_id] += points
    player_scored.emit(player_id, points)

func get_score(player_id: int) -> int:
    return scores.get(player_id, 0)
```

### Notes

- players_by_id is authoritative source for "who's in match"
- packed_players synced via MultiplayerSynchronizer
- Server packs players after roster changes
- Client unpacks players when packed_players setter triggered
- Computed properties use Netcode.server_frame_index for calculations

---

## PlayerState

**File:** `state/player_state.gd`
**Extends:** RefCounted

Abstract base class for player metadata and lifecycle tracking. Represents a single player in multiplayer game.

### Properties

| Name | Type | Description |
|------|------|-------------|
| player_id | int | Unique player ID assigned by server |
| peer_id | int | Peer ID that owns this player |
| local_player_index | int | Local player index (0, 1, 2...) |
| connect_frame_index | int | Frame when player connected |
| disconnect_frame_index | int | Frame when player disconnected |
| is_connected_to_server | bool | Whether currently connected (computed) |

### Abstract Methods

#### get_packed_state() -> Array

Pack player state into array for network replication. **Convention:** player_id MUST be first element (index 0).

**Returns:** Array - Packed state with player_id at index 0

#### populate_from_packed_state(packed_state: Array) -> void

Unpack player state from network array.

**Parameters:**
- `packed_state` (Array): Packed state to unpack

### Static Methods

#### get_player_id_from_packed_state(packed_state: Array) -> int

Extract player_id from packed array without full unpacking.

**Parameters:**
- `packed_state` (Array): Packed state array

**Returns:** int - Player ID (index 0)

### Usage Example

```gdscript
class_name MyPlayerState
extends PlayerState

var player_name: String = ""
var health: int = 100
var inventory: Array[String] = []
var appearance_color: Color = Color.WHITE

func get_packed_state() -> Array:
    return [
        player_id,              # MUST be first (convention)
        peer_id,
        local_player_index,
        connect_frame_index,
        disconnect_frame_index,
        player_name,            # Game-specific
        health,                 # Game-specific
        inventory,              # Game-specific
        appearance_color,       # Game-specific
    ]

func populate_from_packed_state(packed_state: Array) -> void:
    player_id = packed_state[0]
    peer_id = packed_state[1]
    local_player_index = packed_state[2]
    connect_frame_index = packed_state[3]
    disconnect_frame_index = packed_state[4]
    player_name = packed_state[5]
    health = packed_state[6]
    inventory = packed_state[7]
    appearance_color = packed_state[8]
```

### Notes

- player_id is primary key for all player lookups
- **Critical:** player_id MUST be first element in packed arrays
- Subclasses add game-specific properties (name, stats, loadout)
- is_connected_to_server computed from connect/disconnect frame indices
- Used by MatchState for roster replication

---

## InteractionTracker

**File:** `state/interaction_tracker.gd`
**Extends:** RefCounted

Generic utility for interaction deduplication using rollback buffer. Prevents duplicate events during rollback.

### Properties

| Name | Type | Description |
|------|------|-------------|
| deduplication_window_frames | int | Window for deduplication (default: 4 frames) |

### Methods

#### _init(p_rollback_buffer: RollbackBuffer) -> void

Initialize with rollback buffer.

**Parameters:**
- `p_rollback_buffer` (RollbackBuffer): Buffer for storing interaction history

#### has_recent_interaction(entity_a_id: int, entity_b_id: int, current_frame_index: int, interaction_type: int) -> bool

Check if recent interaction exists within deduplication window.

**Parameters:**
- `entity_a_id` (int): First entity ID (order-independent)
- `entity_b_id` (int): Second entity ID (order-independent)
- `current_frame_index` (int): Current server frame
- `interaction_type` (int): Game-specific enum value

**Returns:** bool - True if matching interaction found (duplicate)

#### record_interaction(entity_a_id: int, entity_b_id: int, frame_index: int, interaction_type: int) -> void

Record interaction at given frame.

**Parameters:**
- `entity_a_id` (int): First entity ID
- `entity_b_id` (int): Second entity ID
- `frame_index` (int): Frame when interaction occurred
- `interaction_type` (int): Game-specific enum value

#### set_deduplication_window(frames: int) -> void

Set deduplication window size.

**Parameters:**
- `frames` (int): Window size in frames (typical: 2-8)

#### clear() -> void

Clear all interaction history (auto-pruned by rollback buffer).

### Usage Example

```gdscript
# Setup
var rollback_buffer = RollbackBuffer.new(90, 0, default_state)
var interaction_tracker = InteractionTracker.new(rollback_buffer)

enum InteractionType {
    NONE,
    BUMP,
    KILL,
}

# On server, when collision detected:
func _on_player_collision(player_a_id: int, player_b_id: int) -> void:
    if not interaction_tracker.has_recent_interaction(
        player_a_id,
        player_b_id,
        Netcode.server_frame_index,
        InteractionType.BUMP
    ):
        interaction_tracker.record_interaction(
            player_a_id,
            player_b_id,
            Netcode.server_frame_index,
            InteractionType.BUMP
        )
        # Trigger game logic (damage, score, etc.)
        apply_bump_physics(player_a_id, player_b_id)
```

### Notes

- Essential for server-authoritative interactions during rollback
- Order-independent matching: (A, B) matches (B, A)
- Typical window: 4 frames at 60 FPS (~67ms)
- Larger windows = more aggressive deduplication, more memory
- Use for: kills/deaths, bumps/collisions, pickups, interaction prompts
- Interactions automatically pruned when they fall outside buffer

---

# Utilities

## CircularBuffer

**File:** `core/circular_buffer.gd`
**Extends:** RefCounted

Fixed-size circular buffer (ring buffer) data structure with automatic array pooling.

### Properties

| Name | Type | Description |
|------|------|-------------|
| capacity | int | Maximum number of elements buffer can hold |

### Methods

#### _init(p_capacity: int) -> void

Initialize buffer with fixed capacity.

**Parameters:**
- `p_capacity` (int): Buffer capacity (must be > 0)

#### size() -> int

Current number of valid elements.

**Returns:** int - Number of elements

#### is_empty() -> bool

Check if buffer is empty.

**Returns:** bool - True if empty

#### is_full() -> bool

Check if buffer is at capacity.

**Returns:** bool - True if full

#### append(value: Variant) -> int

Add element to buffer. Overwrites oldest if full.

**Parameters:**
- `value` (Variant): Value to append

**Returns:** int - Absolute index of appended element

#### get_latest() -> Variant

Get most recently pushed element.

**Returns:** Variant - Latest element, or null if empty

#### get_oldest() -> Variant

Get oldest element still in buffer.

**Returns:** Variant - Oldest element, or null if empty

#### get_at(index: int) -> Variant

Get element by absolute index.

**Parameters:**
- `index` (int): Absolute index (from append())

**Returns:** Variant - Element, or null if invalid

#### set_at(index: int, value: Variant) -> bool

Set element at index.

**Parameters:**
- `index` (int): Absolute index
- `value` (Variant): New value

**Returns:** bool - True if successful

#### has_at(index: int) -> bool

Check if index is valid.

**Parameters:**
- `index` (int): Index to check

**Returns:** bool - True if valid

#### get_latest_index() -> int

Get index of latest element.

**Returns:** int - Latest index, or -1 if empty

#### get_oldest_index() -> int

Get index of oldest element.

**Returns:** int - Oldest index, or -1 if empty

#### clear() -> void

Clear all elements (releases arrays to pool).

#### to_array() -> Array

Get all elements as array (oldest to newest).

**Returns:** Array - All valid elements

#### for_each(callback: Callable) -> void

Iterate over elements (oldest to newest).

**Parameters:**
- `callback` (Callable): Function with signature (index: int, value: Variant)

### Usage Example

```gdscript
# Create buffer
var buffer = CircularBuffer.new(10)

# Add elements
buffer.append("first")
buffer.append("second")
buffer.append("third")

# Access elements
var latest = buffer.get_latest()  # "third"
var oldest = buffer.get_oldest()  # "first"
var at_index = buffer.get_at(1)   # "second"

# Iterate
buffer.for_each(func(index: int, value: Variant):
    print("Index %d: %s" % [index, value])
)

# Check capacity
if buffer.is_full():
    print("Buffer full - next append overwrites oldest")
```

### Notes

- Fixed size - capacity set at construction
- Wraps around when full (FIFO)
- Automatically releases arrays to ArrayPool when overwriting
- Reuses array slots when same size to reduce allocations
- Absolute indices (from append()) remain valid within window

---

## ArrayPool

**File:** `core/array_pool.gd`
**Extends:** RefCounted

Object pool for arrays to reduce allocations in hot paths. Maintains separate pools by array size.

### Constants

| Name | Value | Description |
|------|-------|-------------|
| MAX_POOL_SIZE_PER_BUCKET | 32 | Maximum arrays per size pool |

### Static Methods

#### acquire(size: int) -> Array

Acquire array of specified size from pool.

**Parameters:**
- `size` (int): Array size

**Returns:** Array - Reused or new array

#### release(arr: Array) -> void

Return array to pool for reuse.

**Parameters:**
- `arr` (Array): Array to release (will be cleared)

#### clear_all_pools() -> void

Clear all pooled arrays (for testing/memory management).

#### get_pool_stats() -> Dictionary

Get pool statistics.

**Returns:** Dictionary - Stats with keys: size buckets, total_pooled, bucket_count

### Usage Example

```gdscript
# Acquire array
var state := ArrayPool.acquire(5)
state[0] = position.x
state[1] = position.y
state[2] = velocity.x
state[3] = velocity.y
state[4] = is_jumping

# Use array...

# Release when done
ArrayPool.release(state)

# Check stats
var stats = ArrayPool.get_pool_stats()
print("Total pooled: %d" % stats.total_pooled)
```

### Notes

- Separate pools by array size to avoid resizing
- Arrays cleared before pooling (set elements to null)
- Pool size limited to prevent unbounded growth
- Critical for rollback buffer performance
- **Testing:** Call clear_all_pools() in before_each() and after_each()
- Thread-safe via static methods

---

## RollbackBuffer

**File:** `core/rollback_buffer.gd`
**Extends:** CircularBuffer

Circular buffer specialized for storing historical network state frames. Extends CircularBuffer with networking-specific features.

### Methods

#### _init(p_capacity: int, p_current_frame_index: int, p_default_frame_state: Array) -> void

Initialize rollback buffer.

**Parameters:**
- `p_capacity` (int): Number of frames to store
- `p_current_frame_index` (int): Starting frame number
- `p_default_frame_state` (Array): Initial values for all properties

#### has_at(index: int) -> bool

Override to support negative indices (-1, -2) for "previous" frames.

**Parameters:**
- `index` (int): Frame index (supports -1 and -2)

**Returns:** bool - True if valid

#### get_at(index: int) -> Variant

Override to support negative indices.

**Parameters:**
- `index` (int): Frame index

**Returns:** Variant - Frame state, or null if invalid

#### set_at(index: int, value: Variant) -> bool

Override to support arbitrary indices (allows gaps).

**Parameters:**
- `index` (int): Frame index
- `value` (Variant): Frame state

**Returns:** bool - True if successful

#### backfill_to_with_last_state(target_index: int) -> void

Fill gaps with last-known state marked as predicted (SERVER_PREDICTED on server, CLIENT_PREDICTED on client).

**Parameters:**
- `target_index` (int): Target frame index

### Usage Example

```gdscript
# Create buffer
var default_state = [Vector2.ZERO, Vector2.ZERO, ReconcilableState.FrameAuthority.CLIENT_PREDICTED]
var buffer = RollbackBuffer.new(90, 0, default_state)

# Store frames
var state_10 = [Vector2(100, 200), Vector2(50, 0), ReconcilableState.FrameAuthority.AUTHORITATIVE]
buffer.set_at(10, state_10)

# Backfill gaps (frames 1-9 filled with frame 0 state)
buffer.backfill_to_with_last_state(9)

# Retrieve frame
var frame_10_state = buffer.get_at(10)

# Access "previous" frames
var previous = buffer.get_at(-1)  # Default state for frame 0
```

### Notes

- Pre-filled with default state on initialization
- Supports negative indices: -1 (previous), -2 (pre-previous)
- Allows arbitrary frame indices (not just sequential)
- Backfilling fills gaps with last-known predicted state (SERVER_PREDICTED or CLIENT_PREDICTED)
- Uses ArrayPool for memory efficiency
- Critical for rollback reconciliation

---

## PerfTracker

**File:** `utils/perf_tracker.gd`
**Extends:** Node

Performance tracking and server-client metric synchronization. Tracks FPS, rollback, fastforward, and ping metrics.

### Properties

| Name | Type | Description |
|------|------|-------------|
| is_ready_to_track | Callable | Optional readiness check (default: always true) |

### Constants

| Name | Value | Description |
|------|-------|-------------|
| PERF_SYNC_INTERVAL_SEC | 15.0 | Server sync interval |
| PERF_SYNC_INITIAL_DELAY_SEC | 5.0 | Initial delay before first sync |
| METRICS_LOG_INTERVAL_SEC | 15.0 | Periodic logging interval |

### Methods

#### _init(config: NetworkSettings, logger: NetworkLogger, time_provider: NetworkTime, orchestrator: NetworkOrchestrator) -> void

Initialize performance tracker.

**Parameters:**
- `config` (NetworkSettings): Configuration
- `logger` (NetworkLogger): Logger
- `time_provider` (NetworkTime): Time provider
- `orchestrator` (NetworkOrchestrator): Orchestrator reference

#### Client Metric Getters

- `get_client_render_fps() -> float`
- `get_client_physics_fps() -> float`
- `get_client_network_fps() -> float`
- `get_client_network_ping_ms() -> float`
- `get_client_rollbacks_per_sec() -> float`
- `get_client_last_rollback_duration_ms() -> float`
- `get_client_last_rollback_frames() -> int`
- `get_client_fastforwards_per_sec() -> float`
- `get_client_last_fastforward_duration_ms() -> float`
- `get_client_last_fastforward_frames() -> int`

#### Min/Max Metric Getters

- `get_min_render_fps() -> float`
- `get_min_physics_fps() -> float`
- `get_min_network_fps() -> float`
- `get_max_network_ping_ms() -> float`
- `get_max_rollbacks_per_sec() -> float`
- `get_max_last_rollback_duration_ms() -> float`
- `get_max_last_rollback_frames() -> int`
- `get_max_fastforwards_per_sec() -> float`
- `get_max_last_fastforward_duration_ms() -> float`
- `get_max_last_fastforward_frames() -> int`

#### Server Metric Getters (Client-only)

- `get_server_physics_fps() -> float`
- `get_server_network_fps() -> float`
- `get_server_rollbacks_per_sec() -> float`
- `get_server_last_rollback_duration_ms() -> float`
- `get_server_last_rollback_frames() -> int`
- `get_server_fastforwards_per_sec() -> float`
- `get_server_last_fastforward_duration_ms() -> float`
- `get_server_last_fastforward_frames() -> int`
- `get_server_min_physics_fps() -> float`
- `get_server_min_network_fps() -> float`
- `get_server_max_rollbacks_per_sec() -> float`
- `get_server_max_last_rollback_duration_ms() -> float`
- `get_server_max_last_rollback_frames() -> int`
- `get_server_max_fastforwards_per_sec() -> float`
- `get_server_max_last_fastforward_duration_ms() -> float`
- `get_server_max_last_fastforward_frames() -> int`

### Usage Example

```gdscript
# Access via singleton
var perf = Netcode.perf_tracker

# Set readiness check (optional)
perf.is_ready_to_track = func() -> bool:
    return MyGame.is_level_loaded

# Get metrics
var fps = perf.get_client_physics_fps()
var ping = perf.get_client_network_ping_ms()
var rollbacks = perf.get_client_rollbacks_per_sec()

# Display in UI
$Label.text = "FPS: %.1f | Ping: %.1fms | Rollbacks: %.2f/s" % [fps, ping, rollbacks]
```

### Notes

- Automatically tracks render, physics, network FPS
- Calculates rollback and fastforward rates
- Server syncs metrics to clients every 15 seconds
- Registers custom Performance monitors in preview mode
- Logs warnings for performance issues (throttled to 5 seconds)
- Min/max tracked over 10-second windows
- Rate metrics tracked over 60-second windows

---

## FrameAuthority

**Defined in:** `core/reconcilable_state.gd`

Frame authority enumeration for rollback netcode. Distinguishes between
authoritative server state, server extrapolation (guessing), and client
prediction.

### Enum Values

| Value | Description |
|-------|-------------|
| UNKNOWN | Authority is unknown or uninitialized |
| AUTHORITATIVE | Server has real input, state is authoritative |
| SERVER_PREDICTED | Server guessing input (extrapolating), lower confidence |
| CLIENT_PREDICTED | Client has real input, predicting outcome |

### Usage Example

```gdscript
# Access via ReconcilableState class
var frame_authority := ReconcilableState.FrameAuthority.CLIENT_PREDICTED

# Check authority
if frame_authority == ReconcilableState.FrameAuthority.AUTHORITATIVE:
    # Server-confirmed state with real input
    pass
elif frame_authority == ReconcilableState.FrameAuthority.SERVER_PREDICTED:
    # Server extrapolation (no input yet), may be overridden
    pass
elif frame_authority == ReconcilableState.FrameAuthority.CLIENT_PREDICTED:
    # Client prediction, may be rolled back
    pass
```

### Notes

- Stored in rollback buffer with each frame state
- Server sends AUTHORITATIVE when it has real client input
- Server sends SERVER_PREDICTED when extrapolating (no input yet)
- Clients always re-simulate locally as CLIENT_PREDICTED
- Only AUTHORITATIVE states trigger rollback on mismatch
- Clients ignore SERVER_PREDICTED states by default (use local predictions)
- Exception: ForwardedPlayerInputFromServer accepts SERVER_PREDICTED (no local
  alternative)

---

## Quick Reference: Common Patterns

### Creating a Networked Entity

```gdscript
@tool
class_name MyState
extends ReconcilableState

var position := Vector2.ZERO
var velocity := Vector2.ZERO

var _synced_properties_and_rollback_diff_thresholds := {
    "position": 1.0,
    "velocity": 10.0,
}

func _get_is_server_authoritative() -> bool:
    return true

func _has_non_rollbackable_interactions() -> bool:
    return false

func _get_default_values() -> Array:
    return [Vector2.ZERO, Vector2.ZERO]

func _sync_to_scene_state(_previous_state: Array) -> void:
    root.position = position
    root.velocity = velocity

func _sync_from_scene_state() -> void:
    position = root.position
    velocity = root.velocity

func _restore_indirect_interaction_state(_frame_state: Array) -> void:
    pass

func _ready() -> void:
    super._ready()
    call_deferred("record_initial_state")
```

### Implementing Logger

```gdscript
class_name MyLogger
extends NetworkLogger

func info(message: String, category: StringName = CATEGORY_DEFAULT) -> void:
    print("[INFO][%s] %s" % [category, message])

func warning(message: String, category: StringName = CATEGORY_DEFAULT) -> void:
    push_warning("[%s] %s" % [category, message])
```

### Implementing Time Provider

```gdscript
class_name MyTime
extends NetworkTime

var _timers := {}
var _next_id := 1

func set_timeout(callback: Callable, delay_sec: float) -> int:
    var timer := get_tree().create_timer(delay_sec)
    var id := _next_id
    _next_id += 1
    _timers[id] = timer
    timer.timeout.connect(func():
        callback.call()
        _timers.erase(id)
    )
    return id
```

### Accessing Singleton

```gdscript
# Assuming you've set up Netcode singleton
var current_frame = Netcode.server_frame_index
var is_server = Netcode.is_server
var connector = Netcode.connector
var frame_driver = Netcode.frame_driver
```

---

## See Also

- **ARCHITECTURE.md** - High-level architecture overview
- **INTEGRATION.md** - Step-by-step integration guide
- **examples/simple_game/** - Complete working example
- **CLAUDE.md** - Project-specific implementation notes
