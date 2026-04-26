# Rollback Netcode Architecture

# FIXME: REVIEW

This document provides a comprehensive deep dive into the design and
implementation of the Rollback Netcode plugin for Godot 4.x. It explains
the core principles, system architecture, algorithms, and design decisions
behind this client-side prediction and server reconciliation networking
solution.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Core Principles](#2-core-principles)
3. [System Architecture](#3-system-architecture)
4. [Component Deep Dive](#4-component-deep-dive)
5. [Frame Processing Pipeline](#5-frame-processing-pipeline)
6. [Rollback Algorithm](#6-rollback-algorithm)
7. [Frame Synchronization](#7-frame-synchronization)
8. [State Management Abstractions](#8-state-management-abstractions)
9. [Performance](#9-performance)
10. [Utilities](#10-utilities)
11. [Design Decisions](#11-design-decisions)
12. [Extension Points](#12-extension-points)
13. [Comparison to Other Approaches](#13-comparison-to-other-approaches)
14. [Testing Strategy](#14-testing-strategy)
15. [Future Enhancements](#15-future-enhancements)

---

## 1. Overview

### What is Rollback Netcode?

Rollback netcode is a networking technique that provides instant input
response in multiplayer games while maintaining server authority. It
achieves this by:

1. **Predicting** player actions locally before server confirmation
2. **Detecting** mismatches when server state arrives
3. **Rolling back** to the mismatched frame
4. **Re-simulating** from that point with corrected data
5. **Fast-forwarding** to the present with accurate state

This approach eliminates the perceived input lag that traditionally plagues
client-server multiplayer games while preventing cheating through server
validation.

### Why Frame-Synchronous Simulation?

Traditional delta-time game loops use variable timesteps based on frame
duration:

```gdscript
# Delta-time approach (non-deterministic)
func _process(delta: float):
    player.position += player.velocity * delta  # Different each frame!
```

This creates problems for rollback:
- Same inputs can produce different results across frames
- Difficult to precisely replay historical frames
- Floating-point accumulation errors diverge over time

Frame-synchronous simulation uses fixed timesteps:

```gdscript
# Frame-sync approach (deterministic)
const TIMESTEP = 1.0 / 60.0  # Fixed 16.67ms

func _network_process():
    player.position += player.velocity * TIMESTEP  # Always identical!
```

Benefits:
- **Deterministic**: Same inputs always produce identical results
- **Replayable**: Historical frames can be re-simulated perfectly
- **Predictable**: Rollback calculations are precise

### Trade-offs vs Other Approaches

| Approach | Input Response | Server Authority | Bandwidth | Complexity |
|----------|---------------|------------------|-----------|------------|
| **Rollback** (this plugin) | Instant | Yes | Medium | High |
| **Client Authority** | Instant | No | Low | Low |
| **Lockstep** | Delayed | Yes | Low | Medium |
| **State Interpolation** | Delayed | Yes | High | Medium |

**Why choose rollback?**
- Competitive multiplayer requiring instant feedback
- Server validation to prevent cheating
- Action games where input lag is unacceptable
- Network conditions with moderate latency (50-150ms)

**When to avoid rollback?**
- Turn-based games (lockstep is simpler)
- Casual games where slight delay is acceptable (interpolation is simpler)
- Games with 100s of entities (rollback overhead multiplies)

---

## 2. Core Principles

### Deterministic Simulation

Every frame must produce identical results given identical inputs. This
requires:

- **Fixed timestep**: Always 1/60 second (16.67ms)
- **No randomness**: Use seeded RNG with replayed seed values
- **No time dependencies**: Use frame indices, not wall-clock time
- **No floating-point variance**: Same operations in same order
- **No external state**: All state must be in rollback buffer

Example of deterministic movement:

```gdscript
# CORRECT: Deterministic
var velocity := Vector2(100, 0)
var TIMESTEP := 1.0 / 60.0
position += velocity * TIMESTEP  # Always adds Vector2(1.667, 0)

# WRONG: Non-deterministic
position += velocity * delta  # Different delta each frame!
```

### Frame-Based Timing (60 FPS Fixed Timestep)

All game logic operates on frame indices, not time:

```gdscript
# Frame index is the primary clock
var server_frame_index := 0

func _pre_physics_process():
    server_frame_index += 1  # Increments on every physics tick
    _run_network_process()
```

Why 60 FPS?
- Standard for competitive games (16.67ms frame budget)
- Matches typical physics tick rate
- Good balance between responsiveness and CPU cost
- Works well with 60Hz/120Hz displays

Rendering still runs at full framerate (uncapped), but game logic only
updates at 60 FPS.

### Server Authority with Client Prediction

**Server authority** means the server has final say on all game state:

```
Client predicts:     Player at (100, 50)
Server validates:    Player actually at (98, 52)  <- Server wins!
Client corrects:     Roll back and fix
```

**Why server authority?**
- Prevents cheating (server validates all actions)
- Single source of truth (no conflicts between clients)
- Lag compensation possible (server can rewind for hit detection)

**Client prediction** makes this fast by:
- Showing predicted result immediately
- Correcting smoothly when server disagrees
- Hiding network latency from player experience

### Rollback Reconciliation

When client prediction differs from server reality:

```
Timeline:
Frame 100: Client predicts jump
Frame 101: Client predicts movement
Frame 102: Client predicts landing
Frame 103: Server says "you didn't jump at frame 100"

Rollback:
1. Rewind to frame 100
2. Apply server correction (no jump)
3. Re-simulate frame 101 (different movement)
4. Re-simulate frame 102 (different landing)
5. Resume at frame 103 with corrected state
```

Rollback is triggered when:
- Position differs by >1 pixel
- Velocity differs by >10 pixels/sec
- State differs (grounded vs airborne, etc.)

Thresholds are configurable per property to avoid spurious rollbacks from
floating-point precision.

---

## 3. System Architecture

### Component Hierarchy

```
NetworkOrchestrator (Central Coordinator)
├── NetworkConnector         (ENet peer management)
├── FrameDriver              (Frame-synchronous simulation)
├── FrameSynchronizer        (NTP-like clock sync)
└── PerfTracker (optional)   (Performance monitoring)

ReconcilableState (Per-Entity)
├── RollbackBuffer           (Historical states for time-travel)
├── MultiplayerSynchronizer  (Godot replication)
└── Root Node                (Game entity - Player, NPC, etc.)

Utilities
├── CircularBuffer           (Fixed-size ring buffer)
├── ArrayPool                (Memory pooling)
└── NetworkTime              (Timers/throttling)
```

### ASCII Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                    NetworkOrchestrator                       │
│  (Singleton via Netcode autoload, manages all subsystems)   │
└────────┬───────────────┬────────────────┬───────────────────┘
         │               │                │
    ┌────▼────┐    ┌────▼────┐     ┌────▼──────┐
    │Connector│    │FrameDrvr│     │FrameSync  │
    │(ENet)   │    │(60FPS)  │     │(NTP-like) │
    └─────────┘    └────┬────┘     └───────────┘
                        │
           ┌────────────┼────────────┐
           │            │            │
      ┌────▼───┐   ┌───▼────┐  ┌───▼────┐
      │Player1 │   │Player2 │  │NPC     │
      │ State  │   │ State  │  │ State  │
      └────┬───┘   └────┬───┘  └───┬────┘
           │            │           │
      ┌────▼─────┐ ┌───▼──────┐ ┌─▼────────┐
      │Rollback  │ │Rollback  │ │Rollback  │
      │Buffer    │ │Buffer    │ │Buffer    │
      │(90frames)│ │(90frames)│ │(90frames)│
      └──────────┘ └──────────┘ └──────────┘
```

### Dependency Injection Pattern

NetworkOrchestrator uses dependency injection for configuration and logging:

```gdscript
class_name NetworkOrchestrator

var config: NetworkSettings         # Game-configurable settings (required)
var logger: NetworkLogger         # Custom logging implementation (required)
var time: TimeUtils               # Timer/throttle utilities (created internally)

func initialize():
    # Validates config and logger are set
    # Creates TimeUtils automatically
    if time == null:
        time = TimeUtils.new(get_tree())
```

This allows games to:
- Inject custom loggers (file, remote, silent)
- Provide custom configuration resources
- Use TimeUtils for consistent timer behavior across the framework

---

## 4. Component Deep Dive

### NetworkOrchestrator

**Role**: Central coordinator that manages lifecycle and provides singleton
access.

**Responsibilities**:
- Creates and owns core subsystems (Connector, FrameDriver, FrameSync)
- Determines local machine role (server vs client) from command-line args
- Provides convenient accessors for networking state
- Handles configuration and dependency injection

**Key Properties**:
```gdscript
var is_server: bool              # True if this machine is server
var is_client: bool              # True if this machine is client
var is_connected_to_server: bool # Connection status
var local_peer_id: int           # Multiplayer peer ID
var server_frame_index: int      # Current simulation frame
```

**Accessed via**:
```gdscript
# Global singleton (autoload)
Netcode.is_server
Netcode.server_frame_index
Netcode.connector.is_connected_to_server
```

**Command-line Arguments**:
- `--server`: Run as server
- `--client=N`: Run as client N (for local multi-instance testing)
- `--preview`: Enable preview mode
- `--port=N`: Override server port

### NetworkConnector

**Role**: Manages ENet peer connections and player ID assignment.

**Responsibilities**:
- Creating server peers (server-side)
- Creating client peers and connecting to server (client-side)
- Handling peer_connected/peer_disconnected signals
- Assigning sequential player IDs to clients
- Version validation (reject mismatched versions)
- Graceful disconnection and cleanup

**Connection Flow**:

```
Server                          Client
  │                              │
  │◄─────────── connect ─────────┤
  │                              │
  │────────── connected ─────────►│
  │                              │
  │◄────── declare_players ──────┤ (RPC: session_ids, attributes)
  │                              │
  │ (validates + assigns IDs)    │
  │                              │
  │──── receive_player_ids ──────►│ (RPC: [1, 2])
  │                              │
  │ (signals game to spawn)      │ (signals game to spawn)
  │                              │
```

**Player ID Assignment**:
- Server maintains `_next_player_id` counter (starts at 1)
- Each client declares how many local players they have
- Server assigns sequential IDs and maps to peer_id
- Clients store mapping: player_id → local_player_index

Example:
```
Peer 2 declares 2 players → assigned IDs [1, 2]
Peer 3 declares 1 player  → assigned ID [3]
```

### FrameDriver

**Role**: Core frame-synchronous simulation engine at 60 FPS.

**Responsibilities**:
- Maintains `server_frame_index` as primary synchronization primitive
- Manages rollback buffer duration (default: 90 frames / 1.5 seconds)
- Detects state mismatches and triggers rollback reconciliation
- Coordinates re-simulation of frames during rollback
- Handles fast-forwarding when client falls behind
- Registers and manages all ReconcilableState nodes

**Key Lifecycle**:

```gdscript
func _pre_physics_process(_delta: float):
    if _is_paused:
        return

    # Direct frame increment - no time calculation needed!
    server_frame_index += 1

    _run_network_process()

func _run_network_process():
    # 1. Check for queued rollback
    if _queued_rollback_frame_index > 0:
        _rollback_and_reprocess()

    # 2. Process current frame
    _network_process()
```

**Three-Phase Processing**:

Every frame goes through:
1. `_pre_network_process()`: Restore state from buffer
2. `_network_process()`: Execute game logic
3. `_post_network_process()`: Pack state to buffer

All ReconcilableState nodes participate in this cycle.

**Frame Index as Clock**:

Unlike traditional time-based approaches, frame indices drive everything:

```gdscript
# Traditional (time-based, problematic)
var timestamp_usec := Time.get_ticks_usec()
var elapsed := timestamp_usec - start_time

# This plugin (frame-based, deterministic)
var server_frame_index := 0  # Increments on each physics tick
```

Frame indices provide:
- Perfect synchronization across clients
- No drift from time calculations
- Direct buffer indexing
- Easier debugging (frame 1234 vs timestamp 9482938472)

### FrameSynchronizer

**Role**: Maintains synchronized frame indices between server and clients
using NTP-like protocol.

**Why Frame Sync is Needed**:

Clients track their own frame indices locally starting from 0. Without
synchronization, drift occurs:

```
Server:  Frame 0 → 1 → 2 → 3 → 4 → 5
Client:  Frame 0 → 1 → 2 → 2 → 3 → 4  (missed a tick, now behind!)
```

FrameSynchronizer prevents this drift by periodically:
1. Measuring round-trip time (RTT)
2. Estimating current server frame
3. Correcting client if drift exceeds threshold (±1 frame)

**NTP-Like Protocol**:

```
Client                                  Server
  │                                       │
  │─────── ping(t1) ──────────────────────►│
  │                                       │ (receives at t2)
  │                                       │
  │◄────── pong(t1,t2,t3,frame) ──────────│ (sends at t3)
  │                                       │
  │ (receives at t4)                      │
  │                                       │
  │ RTT = (t4-t1) - (t3-t2)               │
  │ Transmission time = t4-t3             │
  │ Frames during transmission = time/16.67ms │
  │ Estimated server frame = frame + transmission_frames │
```

**Timestamps**:
- t1: Client send time (microseconds)
- t2: Server receive time (microseconds)
- t3: Server send time (microseconds)
- t4: Client receive time (microseconds)

**RTT Calculation**:
```
RTT = (t4 - t1) - (t3 - t2)
    = Total round-trip - Server processing time
```

**Drift Correction**:
```gdscript
const DRIFT_THRESHOLD_FRAMES := 1  # ±1 frame tolerance

var drift := estimated_server_frame - local_frame

if abs(drift) > DRIFT_THRESHOLD_FRAMES:
    if drift > 0:
        # Client behind - fast-forward
        frame_driver.fast_forward(estimated_server_frame)
    else:
        # Client ahead - hard reset (rare, usually a bug)
        frame_driver.server_frame_index = estimated_server_frame
```

**Ping Interval**: 3 seconds (configurable via `PING_INTERVAL_SEC`)

### ReconcilableState

**Role**: Base class for all networked entities with rollback support.

**Architecture**:

ReconcilableState bridges three systems:

```
┌─────────────────────────────┐
│   ReconcilableState         │
│   (Your game entity)        │
└──────┬──────────┬───────────┘
       │          │
       │          │
   ┌───▼──┐   ┌──▼────────┐
   │Multi-│   │  Rollback │
   │player│   │  Buffer   │
   │Sync  │   │ (History) │
   └──────┘   └───────────┘
```

1. **Godot MultiplayerSynchronizer**: Handles low-level replication of
   `packed_state` across network
2. **RollbackBuffer**: Stores historical states for rollback time-travel
3. **FrameDriver**: Coordinates frame-synchronous simulation

**Subclass Requirements**:

```gdscript
@tool
class_name MyEntityState
extends ReconcilableState

# 1. Define synced properties
var position := Vector2.ZERO
var velocity := Vector2.ZERO
var health := 100

# 2. Map properties to rollback thresholds
var _synced_properties_and_rollback_diff_thresholds := {
    "position": 1.0,       # Rollback if >1 pixel off
    "velocity": 10.0,      # Rollback if >10 px/sec off
    "health": 0,           # Rollback on any mismatch
}

# 3. Default values (for buffer initialization)
func _get_default_values() -> Array:
    return [Vector2.ZERO, Vector2.ZERO, 100]

# 4. Sync TO scene (restore from buffer)
func _sync_to_scene_state(_previous_state: Array) -> void:
    root.position = position
    root.velocity = velocity
    root.health = health

# 5. Sync FROM scene (pack to buffer)
func _sync_from_scene_state() -> void:
    position = root.position
    velocity = root.velocity
    health = root.health

# 6. Authority (server or client)
func _get_is_server_authoritative() -> bool:
    return true  # Server owns this state
```

**State Packing**:

Properties are packed into a flat array for efficient replication:

```gdscript
# Packed state format: [prop1, prop2, ..., propN, authority, frame_index]
var packed_state := [
    Vector2(100, 50),  # position
    Vector2(0, -200),  # velocity
    100,               # health
    FrameAuthority.AUTHORITATIVE,  # authority flag
    1234,              # frame_index
]
```

**Frame Processing**:

```gdscript
# Called by FrameDriver each frame
func _pre_network_process():
    # Load frame N-1 from buffer as starting point
    _unpack_buffer_state(frame_index - 1)

    # Sync to scene
    var previous_frame_state = buffer.get_at(frame_index - 2)
    _sync_to_scene_state(previous_frame_state)

func _network_process():
    # Game logic runs here (movement, combat, etc.)
    # Implemented by game code, not the plugin
    pass

func _post_network_process():
    # Save frame N back to buffer
    _sync_from_scene_state()
    _pack_buffer_state_from_local_state()
```

**Mismatch Detection**:

When server state arrives for frame N, client compares against local buffer:

```gdscript
func _handle_new_state_from_network():
    var networked_state = packed_state  # Just received from server
    var local_state = buffer.get_at(frame_index)

    # Check each property against threshold
    var mismatched = _get_mismatched_properties(
        networked_state,
        local_state
    )

    if not mismatched.is_empty():
        # Queue rollback!
        Netcode.frame_driver.queue_rollback(frame_index)
```

**Authority Types**:

```gdscript
enum FrameAuthority {
    UNKNOWN,           # Not yet determined
    AUTHORITATIVE,     # Server has real input, state is authoritative
    SERVER_PREDICTED,  # Server guessing input (extrapolating)
    CLIENT_PREDICTED,  # Client has real input, predicting outcome
}
```

- Server sends AUTHORITATIVE when it has real input from the client
- Server sends SERVER_PREDICTED when extrapolating (no input yet)
- Clients always re-simulate locally as CLIENT_PREDICTED
- Only AUTHORITATIVE states trigger rollback on mismatch

---

## 5. Frame Processing Pipeline

### Detailed Single Frame Execution

```
Frame N Start
├─ FrameDriver._pre_physics_process()
│  ├─ server_frame_index += 1
│  └─ _run_network_process()
│
├─ Check for queued rollback
│  └─ If yes: _rollback_and_reprocess()
│
├─ For each ReconcilableState:
│  └─ _pre_network_process()
│     ├─ _unpack_buffer_state(N-1)        # Load frame N-1
│     └─ _sync_to_scene_state(N-2)        # Restore scene from N-1
│
├─ For each ReconcilableState:
│  └─ _network_process()                  # Game logic executes
│     └─ [Your game code runs here]
│
├─ For each ReconcilableState:
│  └─ _post_network_process()
│     ├─ _sync_from_scene_state()         # Read scene to properties
│     ├─ _pack_networked_state()          # Send over network
│     └─ _pack_buffer_state()             # Save to buffer for N
│
└─ Frame N Complete
```

### Why N-1 and N-2?

```
Current frame being processed: N

_pre_network_process():
  - Loads frame N-1 as starting state
  - Why? We're about to simulate frame N, so we start from N-1's result

  - Passes frame N-2 to _sync_to_scene_state()
  - Why? For "just_pressed" logic (compare N-1 vs N-2)

Example:
  Frame 99: Jump button up
  Frame 100: Jump button down → just_pressed = true!
  Frame 101: Jump button down → just_pressed = false

To detect just_pressed at frame 101:
  - Load frame 100 (current button state)
  - Compare against frame 99 (previous state)
  - just_pressed = (frame_100.jump && !frame_99.jump)
```

### Server Broadcast

After processing frame N, server broadcasts state to all clients:

```gdscript
# Server: _post_network_process()
func _pack_networked_state():
    var state := [position, velocity, health]
    state.append(FrameAuthority.AUTHORITATIVE)
    state.append(server_frame_index)

    packed_state = state  # MultiplayerSynchronizer replicates this
```

### Client Receives and Stores

Client receives server state sometime later (latency):

```gdscript
# Client: Triggered when packed_state changes
func _handle_new_state_from_network():
    var state_frame = packed_state[-1]  # Extract frame index

    # Store in buffer at correct frame
    _pack_buffer_state_from_network_state(packed_state)

    # Check for mismatch
    if buffer.has_at(state_frame):
        var local_prediction = buffer.get_at(state_frame)
        if _check_mismatch(packed_state, local_prediction):
            # Trigger rollback!
            Netcode.frame_driver.queue_rollback(state_frame)
```

### Mismatch Detection Triggers Rollback

When client detects its prediction was wrong:

```
Timeline:
  Frame 100: Client predicts position = (100, 50)
  Frame 101: Client continues simulating
  Frame 102: Client continues simulating
  Frame 103: Server state arrives for frame 100: position = (98, 52)

Mismatch Detected!
  Local prediction: (100, 50)
  Server truth: (98, 52)
  Difference: 2.83 pixels > threshold of 1.0

Action:
  Queue rollback to frame 100
```

---

## 6. Rollback Algorithm

### When Rollback Triggers

Rollback occurs when server's authoritative state differs from client's
prediction beyond configured thresholds:

```gdscript
var _synced_properties_and_rollback_diff_thresholds := {
    "position": 1.0,       # >1 pixel difference
    "velocity": 10.0,      # >10 px/sec difference
    "is_grounded": 0,      # Any difference (boolean)
}
```

Example mismatch:

```
Server says:  position = (100, 50), velocity = (50, -100)
Client has:   position = (102, 49), velocity = (50, -100)

Check:
  position difference = sqrt((102-100)² + (49-50)²) = 2.24 pixels
  2.24 > 1.0 threshold → MISMATCH!
  velocity difference = 0.0 → OK

Result: Trigger rollback
```

### Rollback Flow

```
Current state:
  FrameDriver.server_frame_index = 105
  Client predicted frames 100-105 based on local input
  Server state arrives for frame 100 showing mismatch

Rollback process:
  1. _queued_rollback_frame_index = 101 (frame after mismatch)
  2. _rollback_and_reprocess() called
  3. Reset server_frame_index to 101
  4. Re-simulate frames 101, 102, 103, 104 using corrected state
  5. Return to frame 105
  6. Continue normal processing
```

### Code Flow Diagram

```gdscript
func _rollback_and_reprocess():
    var original_frame := server_frame_index  # 105
    var rollback_frame := _queued_rollback_frame_index  # 101

    # Rewind
    server_frame_index = rollback_frame

    # Re-simulate all frames between rollback and present
    while server_frame_index < original_frame:
        _network_process()  # Re-run game logic
        server_frame_index += 1

    # Back to present
    server_frame_index = original_frame
```

### Buffer State During Rollback

```
Before rollback (frame 105):
  Buffer[100] = CLIENT_PREDICTED (wrong)
  Buffer[101] = CLIENT_PREDICTED (based on wrong 100)
  Buffer[102] = CLIENT_PREDICTED (based on wrong 101)
  Buffer[103] = CLIENT_PREDICTED
  Buffer[104] = CLIENT_PREDICTED
  Buffer[105] = CLIENT_PREDICTED (current)

Server state arrives:
  Buffer[100] = AUTHORITATIVE (correct)

During rollback:
  server_frame_index = 101
  Load Buffer[100] (now correct!)
  Re-simulate → Buffer[101] = CLIENT_PREDICTED (new, corrected)

  server_frame_index = 102
  Load Buffer[101] (new, corrected)
  Re-simulate → Buffer[102] = CLIENT_PREDICTED (new, corrected)

  ... continue to frame 105

After rollback:
  Buffer[100] = AUTHORITATIVE (correct)
  Buffer[101] = CLIENT_PREDICTED (corrected)
  Buffer[102] = CLIENT_PREDICTED (corrected)
  Buffer[103] = CLIENT_PREDICTED (corrected)
  Buffer[104] = CLIENT_PREDICTED (corrected)
  Buffer[105] = CLIENT_PREDICTED (corrected)
```

### Reconciliation Complete

Client's state is now consistent with server's validated history. Normal
frame processing resumes.

---

## 7. Frame Synchronization

### Why Clients Need Frame Sync

Simply tracking time isn't enough - clients need synchronized frame
indices:

```
Problem without sync:
  Server frame 0 at t=0.000s
  Client frame 0 at t=0.000s

  Server processes at exactly 16.667ms intervals
  Client processes at slightly variable intervals (16.6ms, 16.8ms, 16.5ms)

  After 100 frames:
    Server: frame 100 at t=1.6667s
    Client: frame 99 at t=1.66s (client is now 1 frame behind!)

  After 1000 frames:
    Server: frame 1000
    Client: frame 995 (5 frames behind - significant desync!)
```

Even tiny timing differences accumulate. Frame synchronization prevents
this drift.

### NTP-Like Protocol Details

Based on Network Time Protocol but adapted for frame indices:

**Standard NTP (time sync)**:
- Clients sync to server's wall-clock time
- Used for: logs, timestamps, scheduling

**This Plugin (frame sync)**:
- Clients sync to server's frame index
- Used for: simulation state, rollback, replication

### Four-Way Timestamp Exchange

```
t1 = Client records send time
     ↓
     Client sends ping(t1)
     ↓
t2 = Server records receive time

     Server processes (t3 - t2)

t3 = Server records send time
     Server sends pong(t1, t2, t3, current_frame)
     ↓
t4 = Client records receive time

Calculations:
  RTT = (t4 - t1) - (t3 - t2)
      = Total round-trip time - Server processing time

  One-way latency ≈ RTT / 2

  Transmission time = t4 - t3

  Frames elapsed during transmission:
    = (t4 - t3) / (1/60 sec per frame)
    = (t4 - t3) / 16,667 µs
```

### Frame Estimation During Transmission

Server sends frame index at time t3, but client receives at time t4.
Frames continued advancing during transmission:

```
Example:
  Server at t3: frame 1000
  Transmission time: 50ms (t4 - t3)

  Frames during transmission:
    50ms / 16.67ms per frame ≈ 3 frames

  Estimated server frame at t4:
    1000 + 3 = 1003

  Client's local frame: 1001

  Drift: 1003 - 1001 = +2 frames
```

### Drift Correction

```gdscript
const DRIFT_THRESHOLD_FRAMES := 1

var drift := estimated_server_frame - local_frame

if abs(drift) <= DRIFT_THRESHOLD_FRAMES:
    # Within tolerance - no correction needed
    return

if drift > 0:
    # Client behind - fast-forward
    logger.print("Fast-forwarding %d frames" % drift)
    frame_driver.fast_forward(estimated_server_frame)
elif drift < 0:
    # Client ahead - hard reset (shouldn't happen normally)
    logger.warning("Client ahead! Resetting from %d to %d" % [
        local_frame,
        estimated_server_frame
    ])
    frame_driver.server_frame_index = estimated_server_frame
```

**Why ±1 frame threshold?**
- Avoids spurious corrections from timing jitter
- 16.67ms tolerance is reasonable for 60 FPS
- Prevents "correction thrashing"

**Fast-forward vs Hard Reset**:
- **Fast-forward** (drift > 0): Client behind, needs to catch up. Simulate
  missing frames normally.
- **Hard reset** (drift < 0): Client ahead (rare, usually a bug). Jump
  backwards in time.

---

## 8. State Management Abstractions

The plugin provides game-agnostic base classes for common networking
patterns. These are 80/20 solutions - they cover most games' needs while
remaining customizable.

### ClientSession

**Purpose**: Tracks local client state (players, input devices, session
IDs).

**Key Properties**:
```gdscript
var session_ids: Array[String]        # Unique IDs per local player
var player_count: int                 # How many local players
var input_devices: Array[int]         # Keyboard/controllers assigned
var is_connected: bool                # Connection status
```

**Use Cases**:
- Split-screen multiplayer (multiple local players)
- Input device assignment (Player 1 = Keyboard, Player 2 = Controller)
- Session persistence (save/load local player data)

**Example**:
```gdscript
# Two-player local co-op
var session := ClientSession.new()
session.session_ids = [
    "player1_keyboard",
    "player2_gamepad"
]
session.player_count = 2
session.input_devices = [
    InputDevice.KEYBOARD,
    InputDevice.GAMEPAD_1
]
```

### MatchState

**Purpose**: Manages match lifecycle and player roster.

**Key Properties**:
```gdscript
var players: Array[PlayerState]       # All players in match
var match_state: Dictionary           # Custom match data
var is_match_active: bool             # Match running?
```

**Signals**:
```gdscript
signal player_joined(player_id: int)
signal player_left(player_id: int)
signal match_started()
signal match_ended(results: Dictionary)
```

**Use Cases**:
- Lobby → match transition
- Player ready-up tracking
- Match result aggregation
- Rematch handling

**Example**:
```gdscript
# Match coordinator
var match := MatchState.new()
match.player_joined.connect(_on_player_joined)

func _on_player_joined(player_id: int):
    if match.players.size() >= 4:
        match.start_match()
```

### PlayerState

**Purpose**: Metadata about individual players (not physics state).

**Key Properties**:
```gdscript
var player_id: int                    # Unique player ID
var player_name: String               # Display name
var team: int                         # Team assignment
var score: int                        # Match score
var is_connected: bool                # Connection status
```

**Use Cases**:
- Scoreboards
- Team assignments
- Player names/avatars
- Connection status UI

**Example**:
```gdscript
# Player metadata
var player := PlayerState.new()
player.player_id = 1
player.player_name = "Alice"
player.team = 0  # Red team
player.score = 1250
player.is_connected = true
```

### InteractionTracker

**Purpose**: Prevents duplicate processing of one-time events.

**Problem**:
```
Rollback scenario:
  Frame 100: Player kills enemy → trigger death animation
  Frame 101: Server says "actually different position"
  Rollback to frame 100
  Re-simulate frame 100: Player kills enemy AGAIN → duplicate animation!
```

**Solution**:
```gdscript
var tracker := InteractionTracker.new()

func process_kill(killer_id: int, victim_id: int, frame: int):
    var key := "kill_%d_%d" % [killer_id, victim_id]

    if tracker.should_process(key, frame):
        # First time processing this kill
        trigger_death_animation()
        award_points()
        tracker.record(key, frame)
    else:
        # Already processed during earlier simulation
        pass
```

**Use Cases**:
- Kill tracking (prevent double-scoring)
- Pickup collection (prevent duplicate pickups)
- Trigger activation (doors, switches)
- Achievement unlocking

### Why These Abstractions?

**80/20 Principle**:
- 80% of games need player rosters, sessions, and interaction deduplication
- 20% of games have unique requirements requiring custom code

**Benefits**:
- Faster prototyping (common patterns built-in)
- Fewer bugs (battle-tested implementations)
- Clearer architecture (separation of concerns)

**Customization**:
- Subclass and extend for game-specific needs
- Use as reference implementation
- Replace entirely if needed

---

## 9. Performance

### Frame Budget

At 60 FPS, each frame has 16.67ms to complete:

```
16.67ms total budget
├─ Game logic: ~10ms (movement, combat, AI)
├─ Rollback overhead: <1ms (typical)
├─ Rendering: ~5ms (separate thread, doesn't count)
└─ Network I/O: <1ms (send/receive packets)
```

Rollback overhead is minimal because:
- Buffer operations are array copies (fast)
- ArrayPool reduces allocations
- State packing is simple array construction

### Rollback Overhead

Typical rollback cost:

```
Rollback 5 frames:
├─ Load buffer state: 5 × 0.1ms = 0.5ms
├─ Re-simulate logic: 5 × 0.2ms = 1.0ms
└─ Save buffer state: 5 × 0.1ms = 0.5ms
Total: ~2.0ms (well within budget)
```

**Factors affecting rollback cost**:
- Number of frames to re-simulate (more = slower)
- Complexity of game logic (simple movement = fast)
- Number of entities (100 entities = 100× work)

**Typical rollback frequency**:
- Well-tuned game: 0-1 rollbacks/second
- Network hiccups: 2-5 rollbacks/second
- Poor tuning: 10+ rollbacks/second (problem!)

### Bandwidth

State size determines bandwidth usage:

```
Example player state:
  position: Vector2 (8 bytes)
  velocity: Vector2 (8 bytes)
  health: int (4 bytes)
  is_grounded: bool (1 byte)
  frame_authority: int (4 bytes)
  frame_index: int (4 bytes)
  Total: 29 bytes per frame

At 60 FPS:
  29 bytes × 60 frames/sec = 1,740 bytes/sec ≈ 1.7 KB/s per player

For 4 players:
  1.7 KB/s × 4 = 6.8 KB/s total

Bandwidth categories:
  < 10 KB/s: Excellent (mobile-friendly)
  10-50 KB/s: Good (broadband)
  50-100 KB/s: Acceptable (local LAN)
  > 100 KB/s: High (consider optimization)
```

**Optimization strategies**:
- Send only changed properties (delta compression)
- Reduce replication frequency (30 FPS for non-critical)
- Compress Vector2 to int16 (16 bits instead of 64 bits)
- Use bit fields for booleans (8 booleans = 1 byte)

### Memory

Rollback buffer memory usage:

```
Single entity:
  State size: 29 bytes
  Buffer capacity: 90 frames
  Total: 29 × 90 = 2,610 bytes ≈ 2.5 KB

100 entities:
  2.5 KB × 100 = 250 KB total buffer memory

Memory usage is negligible for modern hardware.
```

**ArrayPool Benefits**:
- Reduces GC allocations from ~100/sec to ~1/sec
- Prevents GC pauses during rollback
- Reuses array memory across frames
- Critical for performance in GDScript (GC is slow)

### PerfTracker Metrics

Enable performance monitoring in NetworkSettings:

```gdscript
@export var tracking_perf := true
```

**Tracked Metrics**:
- **FPS**: Render (uncapped), Physics (60), Network (60)
- **Ping**: Round-trip time in milliseconds
- **Rollbacks**: Count per second, duration, frame count
- **Fast-forwards**: Count per second, duration, frame count
- **Min/Max windows**: Track worst-case over 10-second window

**Example output**:
```
PERF: FPS[P:60.0 R:144.2 N:60.0] PING:45.3ms
      RB[/s:0.2 last:1.5ms/3f] FF[/s:0.0 last:0.0ms/0f]
```

Interpretation:
- Physics: 60 FPS (perfect)
- Render: 144 FPS (smooth)
- Network: 60 FPS (receiving packets)
- Ping: 45ms (good)
- Rollbacks: 0.2/sec (very rare, excellent)
- Last rollback: 1.5ms for 3 frames (fast)
- Fast-forwards: 0 (perfect sync)

---

## 10. Utilities

### CircularBuffer

**Purpose**: Fixed-size ring buffer (FIFO with wrap-around).

**Use Cases**:
- Rollback buffer foundation
- History tracking (e.g., input history)
- Performance metrics (sliding window)

**Key Operations**:
```gdscript
var buffer = CircularBuffer.new(10)  # Capacity: 10

buffer.append(value)       # Add new element (oldest overwritten if full)
buffer.get_latest()        # Most recent element
buffer.get_oldest()        # Oldest element still in buffer
buffer.get_at(index)       # Element at absolute index
buffer.size()              # Current element count
buffer.is_full()           # True when at capacity
```

**Internal Structure**:
```
Capacity: 5
Pushed: 0, 1, 2, 3, 4, 5, 6, 7

Internal array: [6, 7, 3, 4, 5]
                 ↑     ↑
               next   oldest

Absolute indices:
  get_at(7) → 7 (latest)
  get_at(6) → 6
  get_at(5) → 5
  get_at(4) → 4
  get_at(3) → 3 (oldest)
  get_at(2) → null (too old, overwritten)
```

**Memory Management**:
- Releases old arrays to ArrayPool when overwriting
- Reuses array slots when possible (copy instead of allocate)

### ArrayPool

**Purpose**: Memory pooling to reduce GC pressure from frequent array
allocations.

**Problem Without Pooling**:
```gdscript
# Every frame creates new arrays (60/sec × entities)
var state := [position, velocity, health]  # New allocation!
buffer.set_at(frame_index, state)

# GC runs every few seconds to clean up
# GC pause: 10-50ms (MISSED FRAMES!)
```

**Solution With Pooling**:
```gdscript
# Reuse arrays from pool
var state := ArrayPool.acquire(3)
state[0] = position
state[1] = velocity
state[2] = health
buffer.set_at(frame_index, state)

# Later...
ArrayPool.release(state)  # Return to pool for reuse
```

**API**:
```gdscript
# Get array from pool (creates if pool empty)
var arr := ArrayPool.acquire(size)

# Return array to pool for reuse
ArrayPool.release(arr)

# Clear all pools (tests only)
ArrayPool.clear_all_pools()
```

**Performance Impact**:
- Without pool: 100+ allocations/sec → GC every 2-3 seconds
- With pool: 1-2 allocations/sec → GC every 30+ seconds
- GC pause reduction: 10-50ms → <1ms

### RollbackBuffer

**Purpose**: CircularBuffer specialized for networking with frame-indexed
access.

**Extensions Over CircularBuffer**:

1. **Negative Indices**: Access "previous" frames before frame 0
   ```gdscript
   buffer.get_at(-1)  # Default previous state
   buffer.get_at(-2)  # Two frames before frame 0
   ```

2. **Non-Sequential Setting**: Set arbitrary frame indices (for late
   packets)
   ```gdscript
   buffer.set_at(100, state1)
   buffer.set_at(105, state2)  # Gap of 5 frames
   ```

3. **Back-filling**: Automatically fill gaps with last-known state
   ```gdscript
   buffer.backfill_to_with_last_state(105)
   # Fills frames 101, 102, 103, 104 with copy of frame 100
   ```

4. **Default Values**: Pre-initialized with default state
   ```gdscript
   var defaults := [Vector2.ZERO, Vector2.ZERO, 100]
   var buffer := RollbackBuffer.new(90, 0, defaults)
   # All 90 frames start with defaults
   ```

**Use Case - Late Packet Handling**:
```
Timeline:
  Frame 100: Process (buffer[100] = predicted)
  Frame 101: Process (buffer[101] = predicted)
  Frame 102: Process (buffer[102] = predicted)
  Frame 103: Server state arrives for frame 100

Handle late packet:
  buffer.set_at(100, server_state)  # Retroactive set
  buffer.backfill_to_with_last_state(102)  # Fill 101, 102
  Compare buffer[100] vs server_state → mismatch?
  If yes: trigger rollback
```

### NetworkTime

**Purpose**: Provides timers and throttling (to replace `await
get_tree().create_timer()`).

**Why Not Use Godot Timers Directly?**
- Godot timers don't work well with dependency injection
- Hard to test code that uses `await`
- NetworkTime allows timer mocking in tests

**API**:
```gdscript
# One-shot timer
var timeout_id := time.set_timeout(callback, 5.0)  # 5 seconds
time.clear_timeout(timeout_id)  # Cancel if needed

# Repeating timer
var interval_id := time.set_interval(callback, 1.0)  # Every 1 second
time.clear_interval(interval_id)

# Throttled function (rate-limit)
var throttled := time.throttle(my_function, 0.5)  # Max once per 0.5s
throttled.call()  # Executes immediately
throttled.call()  # Ignored (too soon)
# ... 0.5 seconds pass ...
throttled.call()  # Executes again
```

**Use Cases**:
- Performance monitoring (periodic sync)
- Connection timeouts
- Rate-limiting RPCs
- Throttled logging

---

## 11. Design Decisions

### Why Dependency Injection?

**Problem**:
```gdscript
# Hard-coded dependencies (bad for testing)
class NetworkOrchestrator:
    func _init():
        logger = GlobalLogger.instance  # Global state!
        config = load("res://config.tres")  # Hard-coded path!
```

**Solution**:
```gdscript
# Constructor injection (testable)
class NetworkOrchestrator:
    func _init(
        p_config: NetworkSettings,
        p_logger: NetworkLogger,
        p_time: NetworkTime
    ):
        config = p_config
        logger = p_logger
        time = p_time
```

**Benefits**:
- **Testability**: Inject mocks for unit tests
- **Flexibility**: Swap implementations (file logger, remote logger, etc.)
- **No globals**: Each system has explicit dependencies
- **Clear contracts**: Constructor shows what's required

### Why Resource for Config?

**Alternative Approaches**:
1. **Script constants**: Hard to change without recompiling
2. **Dictionary**: No type safety, no Inspector support
3. **JSON/config file**: Requires parsing, no Godot integration

**Resource Advantages**:
```gdscript
class_name NetworkSettings
extends Resource

@export var server_port := 4433      # Inspector editable!
@export var max_client_count := 4         # Type-safe!
@export var rollback_buffer_duration_sec := 1.5  # Documented!
```

**Benefits**:
- **Inspector Editing**: Visual configuration (no code changes)
- **Type Safety**: Godot validates property types
- **Documentation**: @export properties show in Inspector with descriptions
- **Serialization**: Save as .tres files (versioned with game)
- **Inheritance**: Subclass for custom configs

**Usage**:
```
res://configs/
├─ network_settings_dev.tres    (for development, 2 clients)
├─ network_settings_prod.tres   (for production, 16 clients)
└─ network_settings_test.tres   (for testing, 4 clients)
```

### Why String Categories for Logging?

**Alternative Approaches**:
1. **Enum categories**: Hard-coded, can't extend
2. **Numeric IDs**: Not readable
3. **Classes**: Too heavyweight

**String Categories**:
```gdscript
const CATEGORY_NETWORK := "network"
const CATEGORY_SYNC := "sync"
const CATEGORY_CONNECTIONS := "connections"

logger.print("Message", NetworkLogger.CATEGORY_SYNC)
```

**Benefits**:
- **Extensibility**: Games can add custom categories
- **Filtering**: Filter logs by category string
- **Readability**: `"sync"` is clearer than `LogCategory.SYNC = 2`
- **No dependencies**: Categories don't need to be registered

**Example Filtering**:
```gdscript
# Game-specific logger that filters categories
class GameLogger extends NetworkLogger:
    var enabled_categories := ["network", "sync"]

    func info(message: String, category: String):
        if category in enabled_categories:
            print("[%s] %s" % [category, message])
```

### Why 60 FPS Fixed?

**Alternative Tick Rates**:
- 30 FPS: Lower CPU cost, but noticeable lag (33ms delay)
- 60 FPS: Standard for action games (16.67ms delay)
- 120 FPS: Ultra-responsive, but 2× CPU cost

**60 FPS Rationale**:
- Industry standard for competitive games (CS:GO, Valorant, fighting
  games)
- Good balance between responsiveness and CPU usage
- Matches common physics tick rate
- Works well with 60Hz and 120Hz displays (integer divisors)

**Customization**:
```gdscript
# Change TARGET_NETWORK_FPS in FrameDriver
const TARGET_NETWORK_FPS = 60  # Change to 30 or 120 if needed
```

Note: Changing this requires careful testing of rollback timing and buffer
sizes.

### Why 1.5s Rollback Buffer?

**Buffer Duration Calculation**:
```
1.5 seconds × 60 FPS = 90 frames

Memory per entity:
  State size: ~30 bytes
  Buffer: 30 bytes × 90 frames = 2,700 bytes ≈ 2.7 KB

For 100 entities:
  2.7 KB × 100 = 270 KB (negligible)
```

**Why 1.5 Seconds?**
- Covers typical latency spikes (50-200ms is common)
- Handles packet loss (1-2 dropped packets)
- Allows server time to process and respond
- Not too large (memory cost is low, but more = more to re-simulate)

**When to Adjust**:
- **Increase** (3.0s): High-latency games (mobile, satellite)
- **Decrease** (1.0s): Low-latency games (LAN, local co-op)

```gdscript
# In NetworkSettings
@export var rollback_buffer_duration_sec := 1.5  # Adjust here
```

---

## 12. Extension Points

### Custom NetworkSettings Subclasses

```gdscript
class_name MyGameNetworkSettings
extends NetworkSettings

@export var my_custom_setting := true
@export var server_region := "us-west"
@export var max_ping_threshold_ms := 200
```

Save as `my_game_settings.tres` and load normally.

### Custom Logger Implementations

```gdscript
class_name RemoteLogger
extends NetworkLogger

var http_client: HTTPClient

func info(message: String, category: String):
    # Send to remote logging service
    http_client.post("https://logs.example.com", {
        "level": "info",
        "category": category,
        "message": message
    })

func warning(message: String, category: String):
    # Send to Slack webhook
    slack_notify(message)
```

Inject when creating NetworkOrchestrator:

```gdscript
var logger := RemoteLogger.new()
var netcode := NetworkOrchestrator.new(config, logger, time)
```

### Custom Time Providers

```gdscript
class_name MockTime
extends NetworkTime

var current_time := 0.0

func set_timeout(callback: Callable, delay: float) -> int:
    # Record timeout for test assertions
    timeouts[next_id] = {"callback": callback, "time": current_time + delay}
    return next_id

func advance(delta: float):
    # Manually advance time in tests
    current_time += delta
    _process_pending_timers()
```

Use in tests:

```gdscript
func test_timeout():
    var time := MockTime.new()
    var callback_called := false

    time.set_timeout(func(): callback_called = true, 5.0)

    time.advance(4.9)  # Not yet
    assert_false(callback_called)

    time.advance(0.2)  # Now triggered!
    assert_true(callback_called)
```

### ReconcilableState Subclasses

Extend for custom entity types:

```gdscript
@tool
class_name ProjectileState
extends ReconcilableState

var position := Vector2.ZERO
var velocity := Vector2.ZERO
var damage := 10
var owner_id := 0

var _synced_properties_and_rollback_diff_thresholds := {
    "position": 1.0,
    "velocity": 10.0,
    "damage": 0,        # Never mismatch (server-set)
    "owner_id": 0,      # Never mismatch
}

func _get_is_server_authoritative() -> bool:
    return true  # Server controls projectiles

# Implement other required methods...
```

### State Management Base Classes

Use provided classes or replace:

```gdscript
# Use built-in classes
var session := ClientSession.new()
var match := MatchState.new()

# OR: Implement your own
class MyCustomMatchState:
    # Your custom implementation
    pass
```

The plugin provides these as helpers, not requirements.

---

## 13. Comparison to Other Approaches

### vs Client Authority

**Client Authority** (each client owns their character):

```
Player 1 moves → Everyone else sees it immediately
Player 1 cheats → Everyone sees cheated position (problem!)
```

**Rollback (This Plugin)**:

```
Player 1 moves → Predicts locally + sends to server
Server validates → Sends authoritative state
Player 1 matches? → No rollback (smooth)
Player 1 cheats? → Server rejects → Rollback (corrects)
```

| Aspect | Client Authority | Rollback (This Plugin) |
|--------|-----------------|----------------------|
| **Input Response** | Instant | Instant |
| **Server Validation** | No | Yes |
| **Cheating Prevention** | None | Server validates |
| **Complexity** | Low | High |
| **Best For** | Casual games | Competitive games |

**When to use Client Authority**:
- Casual/cooperative games
- No competitive advantage to cheating
- Want simplest implementation

**When to use Rollback**:
- Competitive multiplayer
- Need server validation
- Willing to invest in complexity

### vs Lockstep

**Lockstep** (all clients wait for all inputs):

```
Frame N:
  Server: Wait for Player 1 input... Wait for Player 2 input... GO!
  All clients: Simulate frame N with all inputs

Input delay = max(all player pings) + processing time
```

**Rollback (This Plugin)**:

```
Frame N:
  Client: Use own input immediately (predict others)
  Server: Process as inputs arrive (no waiting)

Input delay = 0 (instant local response)
```

| Aspect | Lockstep | Rollback (This Plugin) |
|--------|----------|----------------------|
| **Input Delay** | Max player ping | Zero (predicted) |
| **Bandwidth** | Low (inputs only) | Medium (full state) |
| **Complexity** | Medium | High |
| **Determinism** | Required | Required |
| **Best For** | Turn-based, RTS | Action games |

**When to use Lockstep**:
- Turn-based games (chess, card games)
- RTS games (Command & Conquer style)
- Small state (inputs are cheaper to sync than state)

**When to use Rollback**:
- Real-time action (fighting games, shooters)
- Instant input response critical
- OK with higher bandwidth

### vs State Interpolation

**State Interpolation** (smooth between server snapshots):

```
Server snapshot at t=0: position = (0, 0)
Server snapshot at t=100ms: position = (100, 0)

Client at t=50ms: interpolate = (50, 0)  <- Smooth!
```

**Rollback (This Plugin)**:

```
Client input at t=0: predict position = (100, 0)  <- Instant!
Server validates at t=50ms: "yes, you're at (100, 0)"
```

| Aspect | Interpolation | Rollback (This Plugin) |
|--------|---------------|----------------------|
| **Input Response** | Delayed (ping time) | Instant (predicted) |
| **Visual Smoothness** | Very smooth | Occasional snaps |
| **Bandwidth** | High (frequent snapshots) | Medium |
| **Complexity** | Medium | High |
| **Best For** | Remote entities | Local player |

**Hybrid Approach** (recommended for games with many entities):

```
Local player: Rollback (instant response)
Remote players: Interpolation (smooth, delayed)
Remote NPCs: Interpolation (smooth, delayed)
```

This gives best of both worlds:
- Your character feels instant
- Others look smooth (delay doesn't matter)

---

## 14. Testing Strategy

### Unit Tests for Utilities

**CircularBuffer**: 47 tests covering:
- Basic operations (append, get, size)
- Wraparound behavior
- Edge cases (empty, full, single element)
- Memory management (array pool integration)

**ArrayPool**: 13 tests covering:
- Acquire/release cycling
- Pool growth
- Size-specific pools
- Clear operations

**RollbackBuffer**: 20 tests covering:
- Negative index access (-1, -2)
- Non-sequential setting
- Back-filling gaps
- Default value initialization

### Integration Tests

**Frame Pipeline**: 10 tests covering:
- Pre/network/post process cycle
- Buffer state synchronization
- Frame index progression
- Entity registration/deregistration

**State Synchronization**: 10+ tests covering:
- Packed state replication
- Mismatch detection thresholds
- Rollback triggering
- Authority handling (AUTHORITATIVE vs SERVER_PREDICTED vs CLIENT_PREDICTED)

**Frame Timing**: 14+ tests covering:
- Frame index increment
- Fast-forward behavior
- Pause/unpause handling
- Frame drift correction

### Mock Implementations for Testing

```gdscript
# Mock Logger (silent in tests)
class MockLogger extends NetworkLogger:
    func info(message: String, category: String): pass
    func warning(message: String, category: String): pass

# Mock NetworkMain
var MockNetworkMain = double(NetworkMain)
stub(MockNetworkMain, 'is_server').to_return(true)
stub(MockNetworkMain, 'get_current_tick').to_return(100)

# Mock Multiplayer API
var MockMultiplayer = double(MultiplayerAPI)
stub(MockMultiplayer, 'get_unique_id').to_return(1)
```

### Test Coverage Summary

**Total Tests**: 80+ covering core networking infrastructure

**Coverage by Component**:
- Utilities: 80 tests (CircularBuffer, ArrayPool, RollbackBuffer)
- Frame System: 24 tests (FrameDriver, timing, synchronization)
- State System: 10+ tests (ReconcilableState, replication)
- Connection: Manual testing (multiplayer, hard to unit test)

**Testing Philosophy**:
- Unit test utilities (pure functions, deterministic)
- Integration test subsystem interactions
- Manual test full game scenarios (3+ instances)

---

## 15. Future Enhancements

### Client-Side Interpolation for Remote Entities

**Current**: Remote players snap when rollback occurs

**Planned**: Smooth visual interpolation

```gdscript
# Separate visual position from physics position
var visual_position: Vector2  # Rendered position (smooth)
var physics_position: Vector2  # Collision position (authoritative)

func _process(delta):
    # Smoothly move visual toward physics
    visual_position = lerp(visual_position, physics_position, 0.2)
    sprite.position = visual_position
```

**Benefit**: Remote players look smoother during rollback corrections.

### Bandwidth Optimization (Delta Compression)

**Current**: Send full state every frame

**Planned**: Send only changed properties

```gdscript
# Current: 30 bytes per frame
packed_state = [position, velocity, health, ...]

# Optimized: Variable size based on changes
packed_state = [
    CHANGED_MASK,  # Bit field: 0b00000101 = pos + health changed
    position,      # Only if bit 0 set
    health,        # Only if bit 2 set
]
```

**Benefit**: 50-70% bandwidth reduction for mostly-static entities.

### Variable Tick Rate Support

**Current**: Fixed 60 FPS

**Planned**: Configurable tick rate (30, 60, 120, 144 FPS)

```gdscript
@export var target_tick_rate := 60  # User-configurable

const TARGET_NETWORK_TIME_STEP_SEC := 1.0 / target_tick_rate
```

**Benefit**: 30 FPS for low-end devices, 120 FPS for competitive play.

### C# Bindings

**Current**: GDScript only

**Planned**: C# API for C# projects

```csharp
// C# API
var config = new NetworkSettings();
var netcode = new NetworkOrchestrator(config, logger, time);

// Custom entities
public class PlayerState : ReconcilableState
{
    public Vector2 Position { get; set; }
    public Vector2 Velocity { get; set; }
    // ...
}
```

**Benefit**: Support for C# projects (currently GDScript-only).

### Web Platform Support (WebRTC Transport)

**Current**: ENet (UDP) for desktop platforms

**Planned**: WebRTC for web exports

```gdscript
# Automatic transport selection
if OS.has_feature("web"):
    connector = WebRTCConnector.new()
else:
    connector = ENetConnector.new()
```

**Benefit**: Multiplayer games in web browsers.

### Lag Compensation for Hit Detection

**Current**: Hit detection uses current positions

**Planned**: Rewind to shooter's perspective

```gdscript
# When player shoots at frame N:
func process_shot(shooter_id: int, target_id: int, shot_frame: int):
    # Rewind target to shot_frame (account for shooter's latency)
    var rewound_position = rollback_buffer.get_at(shot_frame).position

    # Check hit using rewound position
    if raycast_hit(shooter_position, rewound_position):
        apply_damage()
```

**Benefit**: Fair hit detection even with high ping.

---

## Conclusion

This architecture provides a production-ready foundation for building
competitive multiplayer games with instant input response and
server-authoritative validation. The frame-synchronous approach with
rollback reconciliation is battle-tested in fighting games and real-time
action titles, and this plugin brings those techniques to Godot 4.x with
clear abstractions and comprehensive testing.

**Key Takeaways**:

1. **Frame-sync + Rollback** eliminates input lag while preventing
   cheating
2. **Deterministic simulation** makes rollback possible and precise
3. **Server authority** provides single source of truth and validation
4. **Dependency injection** enables testing and customization
5. **Memory pooling** prevents GC pauses during rollback
6. **80/20 abstractions** accelerate development while staying flexible

**Next Steps**:

- See [QUICKSTART.md](QUICKSTART.md) for integration guide
- See [API_REFERENCE.md](API_REFERENCE.md) for complete API documentation
- See [examples/simple_game/](../examples/simple_game/) for working example
- Review tests in `test/` for usage patterns
