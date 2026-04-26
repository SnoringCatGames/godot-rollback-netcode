# CLAUDE.md

## Overview

Godot 4.5 addon implementing rollback netcode. Game-agnostic;
consumed by Snoring Cat multiplayer titles via git submodule.

## Repo layout

This repo's content **is** the addon. Files at the root (`core/`,
`debug/`, `state/`, `test/`, `utils/`, `examples/`, `plugin.cfg`,
`plugin.gd`) are what consumers see inside their
`addons/rollback_netcode/` directory after submoduling.

```
core/                 NetworkOrchestrator, NetworkConnector, FrameDriver
                      FrameSynchronizer, InputDelayBuffer, etc.
debug/                Network condition simulator and perf overlays.
state/                ReconcilableState base + MatchState / PlayerState /
                      ClientSession abstract classes that games subclass.
test/                 GUT tests.
utils/                Internal helpers (CircularBuffer, ArrayPool, etc.).
examples/simple_game/ Minimal end-to-end demo.
plugin.cfg            Declares the `Netcode` autoload.
plugin.gd             EditorPlugin script that registers the autoload.
```

## Consuming this repo

Add as a git submodule directly at the addon path:

```bash
git submodule add \
    https://github.com/SnoringCatGames/godot-rollback-netcode \
    addons/rollback_netcode
```

After cloning a game project that uses this addon, run:

```bash
git submodule update --init --recursive
```

## Architecture

The addon's `Netcode` autoload owns:

- `NetworkOrchestrator` (autoload entry point)
- `NetworkConnector` (transport selection: ENet/WS/WebRTC)
- `NetworkFrameDriver` (60 FPS frame loop, rollback buffer)
- `FrameSynchronizer` (NTP-style clock sync)
- `InputDelayBuffer`
- `ReconcilableState` (base for all networked entities)
- `StateBundler` (serialization)
- `MatchState` / `PlayerState` / `ClientSession` (abstract bases —
  games provide concrete subclasses)

The `webrtc-native` GDExtension and the GameLift session provider
live separately. This repo is pure GDScript and depends only on
Godot built-ins (no GDExtension required).

## Code style

Follows the GDScript style used in `hopnbop_private`'s CLAUDE.md
(80-char lines, tabs, `not` over `!`, parens for line wrapping,
period-terminated comments).

## Versioning

Independent semver. Decoupled from `snoringcat-platform` because
this addon is genuinely game- and backend-independent.

## Sibling repos

- `snoringcat-platform`
- `godot-gamelift-session-manager`

## Documentation

- `README.md` — user-facing overview.
- `QUICKSTART.md` — 5-minute integration tutorial.
- `ARCHITECTURE.md` — system design deep dive.
- `API_REFERENCE.md` — class and method reference.

The README currently has a "FIXME: REVIEW" annotation at the top
left over from the in-tree development. Documentation cleanup is
tracked as a follow-up.
