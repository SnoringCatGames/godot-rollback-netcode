# CLAUDE.md

## Overview

Godot 4.5 addon implementing rollback netcode. Game-agnostic;
consumed by every Snoring Cat multiplayer title via git submodule.

## Status

Skeleton only. Phase 3 of the platform extraction (see plan in
`~/.claude/plans/in-general-i-ve-been-snoopy-pearl.md`) moves the
implementation here from `hopnbop_private/addons/rollback_netcode/`.

## Architecture (after migration)

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
live in the sibling repo `godot-gamelift-session-manager`. This
repo is pure GDScript and depends only on Godot built-ins.

## Code style

Follows the GDScript style used in `hopnbop_private` — see that
repo's `CLAUDE.md` for formatting and naming conventions.

## Versioning

Independent semver. Decoupled from `snoringcat-platform` because
this addon is genuinely game- and backend-independent.

## Sibling repos

- `snoringcat-platform`
- `godot-gamelift-session-manager`
