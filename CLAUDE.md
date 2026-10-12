# CLAUDE.md

## Overview

Godot 4.7 addon implementing rollback netcode. Game-agnostic;
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
live separately. This repo is pure GDScript (no GDExtension
required). It is meant to depend only on Godot built-ins, but it
still names four hopnbop symbols; see "CI" below.

## Code style

Follows the GDScript style used in `hopnbop`'s CLAUDE.md
(80-char lines, tabs, `not` over `!`, parens for line wrapping,
period-terminated comments).

## CI

`.github/workflows/parse-check.yml` fails on any parse or compile
error in the addon's GDScript. It runs `.github/parse-check/run.sh`,
which builds a minimal project around the addon in a temp dir,
imports it, and loads every script outside `examples/` and `test/`.
It takes seconds; run it before pushing:

```bash
GODOT=/path/to/godot bash .github/parse-check/run.sh
```

`test/` is skipped because its scripts extend GUT's `GutTest`, which
the addon doesn't ship. `examples/simple_game/` is skipped because it
doesn't run. Its `project.godot` points at
`res://addons/rollback_netcode/...` paths that don't exist from its
own root, and four of its six scripts don't compile against the
current addon: `main.gd` calls `NetworkOrchestrator.new(config,
logger, time)` and a `GameTime` that doesn't exist, `player_state.gd`
redeclares `state/player_state.gd`'s `PlayerState` class_name, and
`game_logger.gd`'s overrides no longer match `NetworkLogger`. Fixing
or dropping it is an open decision.

**The addon doesn't compile on its own yet.** Three scripts name
symbols only hopnbop defines: `core/frame_driver.gd` reads
`G.is_lobby_active`, `core/network_connector.gd` types
`session_provider` as `SessionProvider`, and
`state/client_session.gd` names `DeviceConfig` and
`LevelPreferences`. The harness declares those four names in
`.github/parse-check/consumer_stubs/`, so the check covers everything
else and fails on any other game class or autoload the addon names.
It can't see new member accesses on those four: GDScript doesn't
check those at compile time. Delete a stub when its coupling goes.

## Versioning

Independent semver. Decoupled from `snoringcat-platform` because
this addon is genuinely game- and backend-independent.

**`plugin.cfg` `version` is the single source of truth.** There
is no other version field in this repo. Consuming games pin a
submodule SHA, not a version, so nothing breaks if this is
wrong — which is exactly why it silently sat at `1.0.0` from
extraction until 2026-07-16 while the addon changed underneath
it. Treat it as documentation that must not lie.

**Procedure (the agent does this, unprompted):**

- Bump `plugin.cfg` `version` **in the same commit** as any
  change to addon behavior. Not a follow-up commit.
  - MAJOR — breaking change to the public API that consuming
    games call (renamed/removed method, changed signature or
    semantics).
  - MINOR — additive, backward-compatible (new method, new
    optional arg).
  - PATCH — bugfix or internal change with no API change.
- Docs-only, comment-only, CI-only, or test-only changes do
  **not** bump. If in doubt, PATCH.
- Tag `vX.Y.Z` only at deliberate release points, not on every
  bump. A tag means "a consuming game pinned this and it was
  known good", nothing more.

**Known inconsistency (do not be confused by it):** the only tag
in this repo is `v0.1.0`, cut at extraction, while `plugin.cfg`
declared `1.0.0`. The `plugin.cfg` lineage wins; `v0.1.0` is
vestigial. Do not "fix" it by retagging history.

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
