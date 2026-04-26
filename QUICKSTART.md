# Quickstart Guide - 5 Minutes to Multiplayer

# FIXME: REVIEW

Get from zero to a working multiplayer game with client-side prediction and
rollback netcode in 5 minutes.

---

## Prerequisites

- Godot 4.x installed
- Plugin installed in `addons/rollback_netcode/`
- Basic GDScript knowledge

---

## Step 1: Create NetworkSettings (1 minute)

**Create a NetworkSettings resource to configure your netcode settings.**

1. Right-click in FileSystem panel
2. Select "New Resource..."
3. Choose "NetworkSettings"
4. Save as `res://network_settings.tres`
5. Edit in Inspector:
   - `server_port`: 4433 (default)
   - `max_client_count`: 4
   - `rollback_buffer_duration_sec`: 1.5

**Code example** (alternative to .tres file):

```gdscript
# game_settings.gd
class_name GameSettings
extends NetworkSettings

func _init() -> void:
    server_port = 4433
    max_client_count = 4
    rollback_buffer_duration_sec = 1.5
```

---

## Step 2: Implement Logger (1 minute)

**Create a logger class to handle netcode logging output.**

```gdscript
# game_logger.gd
class_name GameLogger
extends NetworkLogger

func verbose(message: String, category: StringName = CATEGORY_DEFAULT) -> void:
    print_rich("[color=gray][VERBOSE][%s] %s[/color]" % [category, message])

func info(message: String, category: StringName = CATEGORY_DEFAULT) -> void:
    print_rich("[color=cyan][INFO][%s] %s[/color]" % [category, message])

func warning(message: String, category: StringName = CATEGORY_DEFAULT) -> void:
    print_rich("[color=yellow][WARNING][%s] %s[/color]" % [category, message])

func error(message: String, category: StringName = CATEGORY_DEFAULT) -> void:
    print_rich("[color=red][ERROR][%s] %s[/color]" % [category, message])

func fatal(message: String, category: StringName = CATEGORY_DEFAULT) -> void:
    print_rich("[color=magenta][FATAL][%s] %s[/color]" % [category, message])
    assert(false, message)
```

---

## Step 3: Initialize Netcode (1 minute)

**Configure and initialize the netcode system.**

The rollback_netcode plugin is added as an autoload singleton named "Netcode"
automatically when the plugin is enabled. You just need to configure it:

```gdscript
# In your main scene or autoload
func _ready() -> void:
    var config := load("res://network_settings.tres") as NetworkSettings
    var logger := GameLogger.new()

    Netcode.settings = config
    Netcode.log = logger
    Netcode.initialize()  # TimeUtils is created automatically

    # Parse command-line args.
    var args := OS.get_cmdline_user_args()
    if "--server" in args:
        Netcode.server_start()
    else:
        Netcode.client_connect("127.0.0.1", 4433)
```

**Note:** The Netcode singleton is automatically available once the plugin is
enabled.

---

## Step 4: Create Player with Prediction (1 minute)

**Create a player scene with networked state synchronization.**

```gdscript
# player.gd (attach to CharacterBody2D)
extends CharacterBody2D

const SPEED := 300.0

func _ready() -> void:
    # Ensure state_from_server exists as child.
    if not has_node("StateFromServer"):
        var state := PlayerState.new()
        state.name = "StateFromServer"
        state.root_path = get_path()
        add_child(state)

func _network_process() -> void:
    # Handle player input and movement at 60 FPS.
    var direction := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
    velocity = direction * SPEED
    move_and_slide()
```

**Create PlayerState class:**

```gdscript
# player_state.gd
@tool
class_name PlayerState
extends ReconcilableState

var position := Vector2.ZERO
var velocity := Vector2.ZERO

var _synced_properties_and_rollback_diff_thresholds := {
    "position": 1.0,  # 1 pixel mismatch threshold.
    "velocity": 10.0,  # 10 pixels/sec mismatch threshold.
}

func _get_is_server_authoritative() -> bool:
    return true

func _has_non_rollbackable_interactions() -> bool:
    return false

func _is_interaction_rollbackable(_interaction_type: int) -> bool:
    return true

func _get_default_values() -> Array:
    return [Vector2.ZERO, Vector2.ZERO]

func _sync_to_scene_state(_previous_state: Array) -> void:
    if is_instance_valid(root):
        root.position = position

func _restore_indirect_interaction_state(_frame_state: Array) -> void:
    pass

func _sync_from_scene_state() -> void:
    if is_instance_valid(root):
        position = root.position
        velocity = root.velocity
```

---

## Step 5: Spawn Players (30 seconds)

**Set up automatic player spawning on connection.**

```gdscript
# main.gd (attach to root node)
extends Node2D

@onready var spawn_container := $Players
var player_scene := preload("res://player.tscn")

func _ready() -> void:
    Netcode.orchestrator.connector.peer_connected.connect(
        _on_peer_connected
    )

    # Spawn local player immediately.
    if not Netcode.is_server:
        _spawn_player(multiplayer.get_unique_id())

func _on_peer_connected(peer_id: int) -> void:
    if Netcode.is_server:
        _spawn_player(peer_id)

func _spawn_player(peer_id: int) -> void:
    var player := player_scene.instantiate()
    player.name = "Player%d" % peer_id
    player.position = Vector2(randf_range(100, 700), randf_range(100, 500))
    spawn_container.add_child(player, true)
```

**Add MultiplayerSpawner** to your scene:

1. Add MultiplayerSpawner node to Main scene
2. Set `Spawn Path` to `Players` (container node)
3. Add `res://player.tscn` to Auto Spawn List

---

## Step 6: Test It (30 seconds)

**Run server and clients to see multiplayer in action.**

**Terminal 1 (Server):**

```bash
godot --headless -- --server
```

**Terminal 2 (Client 1):**

```bash
godot
```

**Terminal 3 (Client 2):**

```bash
godot
```

**What to expect:**

- Players spawn for each connected client
- Movement is instantly responsive (client-side prediction)
- Position stays synchronized across all clients
- Server reconciles any prediction mismatches

---

## Troubleshooting

### Port already in use

**Error:** `ENet: bind() failed`

**Fix:** Change `server_port` in NetworkSettings or kill process using port
4433:

```bash
# Windows
netstat -ano | findstr :4433
taskkill /PID <pid> /F

# Linux/Mac
lsof -i :4433
kill -9 <pid>
```

### Players not spawning

**Check:**

- MultiplayerSpawner `Spawn Path` points to correct container node
- Player scene is in Auto Spawn List
- `_on_peer_connected` is connected to
  `Netcode.orchestrator.connector.peer_connected`

### Rollback not working

**Check:**

- Player has `PlayerState` child node with `@tool` annotation
- `_synced_properties_and_rollback_diff_thresholds` is defined
- `root_path` is set correctly on PlayerState
- `_network_process()` is defined on player (not `_physics_process`)

### Frame rate issues

**Check:**

- Game logic is in `_network_process()` (runs at 60 FPS), not
  `_physics_process`
- Rendering code is in `_process()` (runs at full framerate)
- `rollback_buffer_duration_sec` is not excessively large (default: 1.5)

---

## Next Steps

### Study the complete example

The `examples/simple_game/` directory contains a fully working multiplayer
game demonstrating all features. Run it to see the netcode in action:

1. Open `addons/rollback_netcode/examples/simple_game/project.godot`
2. Configure Run Instances (Debug > Customize Run Instances)
3. Enable 3 instances with args: `--server --preview`, `--client=1 --preview`,
   `--client=2 --preview`
4. Press F5

### Read the architecture docs

`ARCHITECTURE.md` (coming soon) explains how the netcode works internally:

- Frame-synchronous simulation
- Client-side prediction algorithm
- Rollback reconciliation process
- NTP-like frame synchronization

### Explore the API reference

`API_REFERENCE.md` (coming soon) documents all classes and methods:

- `NetworkOrchestrator` - Central coordinator
- `ReconcilableState` - Base class for networked entities
- `FrameDriver` - Frame-sync simulation loop
- `FrameSynchronizer` - Client-server frame sync
- `NetworkConnector` - ENet connection management
