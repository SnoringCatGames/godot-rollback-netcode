# Simple Game - Rollback Netcode Example

# FIXME: Review the example app.

A minimal working example demonstrating the rollback netcode plugin for Godot 4.

## Features

- **Server-authoritative player movement** with client-side prediction
- **Rollback reconciliation** when predictions mismatch server state
- **MultiplayerSpawner** integration for dynamic player instantiation
- **Dependency injection** pattern (NetworkSettings, NetworkLogger, NetworkTime)
- **WASD movement** at 200 pixels/second
- **Color-coded logging** for easy debugging

## Project Structure

```
simple_game/
├── scripts/
│   ├── game_settings.gd         # NetworkSettings implementation
│   ├── game_logger.gd         # NetworkLogger with color-coded output
│   ├── game_time.gd           # NetworkTime with Timer-based implementation
│   ├── netcode_singleton.gd   # Global Netcode singleton (autoload)
│   ├── player_state.gd        # ReconcilableState for player sync
│   ├── player.gd              # CharacterBody2D with movement logic
│   └── main.gd                # Main orchestrator (spawning, connections)
├── scenes/
│   ├── player.tscn            # Player scene (CharacterBody2D + PlayerState)
│   └── main.tscn              # Main scene (spawner, camera)
├── project.godot              # Godot project configuration
└── README.md                  # This file
```

## Running the Example

### Option 1: Command-Line (Recommended)

Open two terminal windows and run:

```bash
# Terminal 1 (Server)
godot --path "c:/Users/lsl/Repositories/hopnbop/addons/rollback_netcode/examples/simple_game" -- --server

# Terminal 2 (Client)
godot --path "c:/Users/lsl/Repositories/hopnbop/addons/rollback_netcode/examples/simple_game"
```

### Option 2: Godot Editor

1. Open the project in Godot: `File > Open Project > simple_game/project.godot`
2. Run the project (F5) - defaults to client mode
3. Open a second instance with `--server` argument for testing

## How It Works

### 1. Plugin Initialization (main.gd)

```gdscript
var config := GameSettings.new()      # Network settings
var logger := GameLogger.new()      # Logging implementation
var time := GameTime.new(get_tree()) # Timer utilities

# Create NetworkOrchestrator
var orchestrator := NetworkOrchestrator.new(config, logger, time)
add_child(orchestrator)

# Register with global Netcode singleton (required by ReconcilableState)
Netcode.initialize(orchestrator)
```

### 2. Server/Client Mode

- **Server mode**: `--server` flag or headless mode (auto-detected)
- **Client mode**: Default when run in editor or as application
- **Port**: 4433 (configurable in GameSettings)

### 3. Player Spawning

- Server spawns players on peer connection
- Each player gets `player_id` (simplified to use `peer_id` directly)
- `NetworkConnector.register_player_state()` called to map player_id to peer_id
- Random spawn position and color for visual distinction
- `MultiplayerSpawner` replicates instantiation to all clients

### 4. Movement & Synchronization

- **Player.gd**: Reads WASD input and updates velocity
- **PlayerState.gd**: Syncs position/velocity with rollback support
- **Client-side prediction**: Players see movement immediately
- **Server reconciliation**: Corrections applied when predictions mismatch

### 5. Rollback Reconciliation

When client prediction differs from server state:

1. **Mismatch detection**: Position drift exceeds 1.0 pixel threshold
2. **Rollback trigger**: FrameDriver restores to mismatched frame
3. **Re-simulation**: All frames from mismatch to present are replayed
4. **Smooth correction**: Visual state interpolates to corrected position

## Key Concepts Demonstrated

### Dependency Injection

The plugin doesn't assume any specific logging or timer system - you provide implementations:

- **NetworkSettings**: Game-specific settings (port, buffer size, etc.)
- **NetworkLogger**: Logging backend (console, file, UI, etc.)
- **NetworkTime**: Timer management (SceneTree timers, custom managers, etc.)

### ReconcilableState Pattern

`PlayerState` extends `ReconcilableState` to enable:

- **Automatic replication**: `packed_state` synced via MultiplayerSynchronizer
- **Rollback buffer**: Historical states stored for time-travel
- **Mismatch detection**: Thresholds define when to trigger rollback
- **Scene sync**: `_sync_to_scene_state()` and `_sync_from_scene_state()` bridge networked properties and scene nodes

### Server Authority

- Server is the source of truth for all player positions
- Clients predict movement locally for responsiveness
- Server corrections override client predictions when mismatches occur

## Customization

### Change Movement Speed

Edit `SPEED` constant in `player.gd`:

```gdscript
const SPEED := 200.0  # Pixels per second
```

### Adjust Rollback Thresholds

Edit thresholds in `player_state.gd`:

```gdscript
var _synced_properties_and_rollback_diff_thresholds := {
	"position": 1.0,   # Position mismatch threshold (pixels)
	"velocity": 10.0,  # Velocity mismatch threshold (pixels/sec)
}
```

### Add More Synced Properties

1. Add property to `PlayerState`:
   ```gdscript
   var health := 100
   ```

2. Add to thresholds dictionary:
   ```gdscript
   var _synced_properties_and_rollback_diff_thresholds := {
	   "position": 1.0,
	   "velocity": 10.0,
	   "health": 0,  # Exact match required
   }
   ```

3. Update `_get_default_values()`:
   ```gdscript
   func _get_default_values() -> Array:
	   return [Vector2.ZERO, Vector2.ZERO, 100]
   ```

## Troubleshooting

### "Connection refused" error

- Ensure server is running before starting client
- Check firewall settings for port 4433

### Players not spawning

- Verify `MultiplayerSpawner` spawn_path points to correct parent
- Check console for spawning errors

### Rollback not triggering

- Increase network latency artificially to test rollback
- Check `tracking_perf = true` in `GameSettings` for stats

### Input not working

- Verify WASD keys are mapped in `project.godot` input settings
- Check `is_multiplayer_authority()` returns true for local player

## Next Steps

This example provides a foundation for building more complex networked games:

- Add health/damage system
- Implement projectile shooting
- Add collision detection between players
- Create game modes (deathmatch, capture the flag, etc.)
- Add UI for lobby, scores, chat, etc.

## License

This example is provided as-is for educational purposes. Use freely in your own projects.
