# godot-rollback-netcode ledger

Open work for the rollback netcode addon: follow-ups, known residuals,
decisions waiting on Levi, and ideas. Convention: claude-config
`rules/ledger.md`. IDs (`RN<n>`) are stable and never reused. The only
consumer today is hopnbop (`addons/rollback_netcode`); game-side items
live in hopnbop's `LEDGER.md`.

Session pointers like "session 530145bc, agent a42eb164" refer to Claude
Code transcripts under `~/.claude/projects/` (kept 30 days). Each item
states its facts, so it stands on its own after the transcript is gone.

## Waiting on Levi

- **RN1** · The addon only compiles inside hopnbop: `core/frame_driver.gd`
  reads `G.is_lobby_active`, `core/network_connector.gd` uses
  `SessionProvider`, and `state/client_session.gd` uses `DeviceConfig`
  and `LevelPreferences`, all defined by hopnbop. The CI parse check
  (`.github/parse-check/run.sh`, 10b2f41) declares stand-ins for those
  four names, documented in CLAUDE.md. Decide: make the addon standalone
  (an API change in both repos; `frame_driver.gd` also holds Levi's
  uncommitted notes in hopnbop's checkout) or keep the stand-ins.
  (Session 530145bc, tooling agent a42eb164, 2026-10-12.)
- **RN2** · `examples/simple_game` is broken: 4 of its 6 scripts don't
  compile against the current addon, while README and QUICKSTART call it
  fully working. Fix it or drop it. (Agent a42eb164.)

## In progress

## Next


## Residuals (known, not fixed)


## Ideas (not scheduled)

## Done

- **RN8** · Pause stats read 0 because frame indices freeze while paused; duration now measured on the wall clock. Done in 8256603 (2026-10-29).
- **RN7** · V17: 4 broken format strings. Done in a7b001d (2026-10-29).
- **RN3** · Offered: the addon's 9 GUT test files run nowhere in CI. Done in d8aae6c (2026-10-29).
