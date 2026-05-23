# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] — 2026-04-25

### Added
- Initial extraction from `hopnbop/addons/rollback_netcode/`
  at tag `pre-platform-extraction`. Addon content lives at the repo
  root so consumers can submodule directly at `addons/rollback_netcode/`.
- Frame-synchronous 60 FPS simulation with client-side prediction
  and server reconciliation.
- Configurable rollback buffer (default ~1.5 seconds / 90 frames).
- ENet, WebSocket, and WebRTC transport support via NetworkConnector.
- Network condition simulator (debug/) for testing under loss/jitter.
- Abstract `MatchState`, `PlayerState`, `ClientSession` base classes
  for game-specific subclassing.
- 90+ GUT tests covering core networking infrastructure.
- Working `examples/simple_game/`.

