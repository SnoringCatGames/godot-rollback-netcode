# Godot Rollback Netcode Plugin


**Client-side prediction with server reconciliation for Godot 4.x**

![Godot](https://img.shields.io/badge/godot-4.x+-green)
![License](https://img.shields.io/badge/license-MIT-orange)

---

## Overview

The Rollback Netcode Plugin provides a complete, production-ready
networking solution for multiplayer Godot games that require instant
input response and server-authoritative gameplay. Built on proven
rollback netcode principles used in competitive fighting games and
real-time action titles, this plugin eliminates the input lag typically
associated with networked multiplayer while maintaining server authority
to prevent cheating.

Traditional client-server networking forces players to wait for
round-trip confirmation before seeing their actions, creating noticeable
delay (50-150ms on typical connections). This plugin solves this problem
by predicting player actions locally and automatically reconciling
differences when the server's authoritative state arrives, providing
instant visual feedback without sacrificing server control.

The plugin is extracted from Hop 'n Bop, a production multiplayer
action game, and comes with comprehensive testing (80+ unit tests),
clear architectural patterns, and working examples to get you started
quickly.

---

## Features

- **Frame-synchronous simulation at 60 FPS** - Deterministic game logic
  decoupled from render framerate
- **Client-side prediction** - Instant local input response with zero
  perceived lag
- **Server-authoritative validation** - Server controls game state to
  prevent cheating
- **Automatic rollback reconciliation** - Smooth correction when
  predictions differ from server
- **NTP-like frame synchronization** - Client-server frame index sync to
  prevent drift
- **Configurable rollback buffer** - Adjustable history duration
  (default: 1.5 seconds / ~90 frames)
- **ENet peer management** - Built-in connection handling with
  MultiplayerAPI integration
- **Optional performance tracking** - Real-time metrics and profiling
  tools
- **Resource-based configuration** - Inspector-friendly NetworkSettings
  .tres files
- **Extensible state management** - ReconcilableState base class for
  custom entities
- **Memory-efficient** - ArrayPool reduces GC pressure from frequent
  state snapshots
- **Production-tested** - 80+ unit tests covering core networking
  infrastructure
- **Complete working examples** - Simple game demonstrating all features

---

## Installation

### From Godot Asset Library (Recommended)

1. Open Godot Editor
2. Navigate to AssetLib tab
3. Search for "Rollback Netcode"
4. Click Download and Install
5. Enable plugin in Project > Project Settings > Plugins

### Manual Installation

1. Clone or download this repository
2. Copy `addons/rollback_netcode/` to your project's `addons/` folder
3. Restart Godot Editor
4. Enable plugin in Project > Project Settings > Plugins
5. Verify plugin loaded by checking for NetworkOrchestrator autoload

---

## Quick Start

### Minimal Setup (5 lines of code)

```gdscript
extends Node

# 1. Create NetworkOrchestrator with config
var config := preload("res://network_settings.tres")
var netcode := NetworkOrchestrator.new(config, MyLogger.new(), MyTime.new())

func _ready() -> void:
    # 2. Add to scene tree
    add_child(netcode)

    # 3. Start server or connect client
    if "--server" in OS.get_cmdline_args():
        netcode.connector.start_server()
    else:
        netcode.connector.connect_to_server("127.0.0.1")
```

For a complete integration guide, see
[QUICKSTART.md](QUICKSTART.md).

For a working example, see
[examples/simple_game/](examples/simple_game/).

---

## Core Concepts

### Frame-Synchronous Simulation

Unlike traditional delta-time game loops, frame-synchronous simulation
runs game logic at a fixed tick rate (60 FPS) independent of rendering.
This ensures deterministic behavior across all clients, making rollback
reconciliation possible. Rendering still runs at full framerate for
smooth visuals.

### Client-Side Prediction

When a player presses a button, the client immediately simulates the
predicted result (movement, attack, etc.) without waiting for server
confirmation. This provides instant visual feedback while the input is
sent to the server in parallel.

### Server Reconciliation

When the server's authoritative state arrives and differs from the
client's prediction, reconciliation corrects the client:

1. Roll back to the mismatched frame
2. Apply the server's correct state
3. Re-simulate all frames from mismatch to present
4. Visual state smoothly catches up

### Rollback Buffer

A circular buffer maintains historical game states (default: 1.5
seconds). When a mismatch is detected, the system "rewinds time" to the
incorrect frame, applies corrections, and fast-forwards back to the
present with corrected data.

### ReconcilableState

The base class for all networked entities. Subclass
ReconcilableState and implement state packing/unpacking to
automatically gain client prediction, server authority, and rollback
support.

---

## Architecture Overview

```
NetworkOrchestrator (Singleton)
├── NetworkConnector         (ENet peer management)
├── FrameDriver              (Frame-sync simulation loop)
├── FrameSynchronizer        (NTP-like frame sync)
└── PerfTracker (optional)   (Performance monitoring)

ReconcilableState (Base Class)
├── Integrates with Godot MultiplayerSynchronizer
├── Manages RollbackBuffer for entity
└── Coordinates with FrameDriver for simulation
```

**Key Components:**

- **NetworkOrchestrator**: Central coordinator providing access to all
  subsystems
- **NetworkConnector**: Handles ENet connections, disconnections, and
  peer management
- **FrameDriver**: Runs frame-synchronous simulation at 60 FPS,
  orchestrates rollback
- **FrameSynchronizer**: Maintains synchronized frame indices between
  client and server
- **ReconcilableState**: Base class for networked entities (players,
  NPCs, projectiles)
- **RollbackBuffer**: Stores historical states for time-travel during
  reconciliation

For detailed architecture documentation, see
[ARCHITECTURE.md](ARCHITECTURE.md).

---

## Examples

The plugin includes a complete working example demonstrating all
features:

### simple_game

A minimal multiplayer game showing:
- Player spawning and movement
- Client-side prediction
- Server reconciliation
- Frame synchronization
- Input handling

**Run the example:**
1. Open `addons/rollback_netcode/examples/simple_game/project.godot`
2. Configure Run Instances (Debug > Customize Run Instances):
   - Enable 3 instances
   - Instance 1: `--server --preview`
   - Instance 2: `--client=1 --preview`
   - Instance 3: `--client=2 --preview`
3. Press F5 to run all instances

For a detailed walkthrough, see
[examples/simple_game/README.md](examples/simple_game/README.md).

---

## Documentation

- **[QUICKSTART.md](QUICKSTART.md)** - 5-minute integration
  tutorial
- **[ARCHITECTURE.md](ARCHITECTURE.md)** - Deep dive into system
  design and algorithms
- **[API_REFERENCE.md](API_REFERENCE.md)** - Complete class and
  method documentation
- **[examples/simple_game/README.md](examples/simple_game/README.md)** -
  Example walkthrough

---

## Configuration

Network behavior is configured via NetworkSettings Resource files:

### Creating a Configuration

1. Right-click in FileSystem panel
2. Select "New Resource..."
3. Choose "NetworkSettings"
4. Save as `network_settings.tres`
5. Edit properties in Inspector

### Key Configuration Options

```gdscript
@export var server_port := 4433
@export var max_client_count := 4
@export var rollback_buffer_duration_sec := 1.5

# Preview mode (editor testing)
@export var is_preview_mode := false
@export var preview_client_count := 2

# Performance
@export var tracking_perf := false
```

Load configuration in code:

```gdscript
var config := load("res://network_settings.tres") as NetworkSettings
var netcode := NetworkOrchestrator.new(config, logger, time_provider)
```

For all configuration options, see the NetworkSettings class
documentation in [API_REFERENCE.md](API_REFERENCE.md).

---

## Testing

The plugin includes 80+ unit tests covering core networking
infrastructure:

### Running Tests

**In Editor (GUT Panel):**
1. Open GUT panel (bottom dock)
2. Navigate to `addons/rollback_netcode/test/`
3. Click "Run All"

**Command Line:**

```bash
# Run all plugin tests
godot --headless -s --path . addons/gut/gut_cmdln.gd \
  -gdir=res://addons/rollback_netcode/test/unit -gexit

# Run specific test file
godot --headless -s --path . addons/gut/gut_cmdln.gd \
  -gtest=res://addons/rollback_netcode/test/unit/test_rollback_buffer.gd \
  -gexit
```

### Test Coverage

- **Core Infrastructure**: CircularBuffer (47 tests), ArrayPool (13
  tests), RollbackBuffer (20 tests)
- **Networking**: FrameDriver, ReconcilableState, FrameSynchronizer
- **Total**: 80+ tests ensuring production reliability

---

## Performance

### Frame Timing
- **Network tick rate**: Fixed 60 FPS (16.67ms per frame)
- **Render framerate**: Uncapped (runs independently)
- **Rollback overhead**: Sub-millisecond for typical state sizes

### Bandwidth
- Depends on state size and replication frequency
- Typical player state: ~100-200 bytes per frame
- At 60 FPS: ~6-12 KB/s per player

### Memory
- ArrayPool reduces GC allocations from state snapshots
- Rollback buffer: ~90 frames × state size (default 1.5 seconds)
- Configurable via `rollback_buffer_duration_sec`

### Monitoring

Enable PerfTracker in NetworkSettings to monitor:
- Frame processing times
- Network packet rates
- Rollback frequency
- Buffer utilization

---

**Ready to get started?** Check out [QUICKSTART.md](QUICKSTART.md)
for a 5-minute integration guide, or dive into the
[examples/simple_game/](examples/simple_game/) for a complete working
example.
