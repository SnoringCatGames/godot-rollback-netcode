# godot-rollback-netcode

Game-agnostic rollback netcode framework for Godot 4.5.

Frame-synchronous client prediction with server reconciliation,
configurable rollback buffer, and pluggable transport (ENet,
WebSocket, WebRTC). Originally built for [Hop 'n Bop](https://github.com/SnoringCatGames/hopnbop)
and now extracted as a reusable addon for future Snoring Cat
multiplayer titles.

## Status

Skeleton. Phase 3 of the platform extraction will move
the implementation here from `hopnbop_private/addons/rollback_netcode/`.

## Features (target)

- 60 FPS fixed network tick rate, independent of render framerate.
- Server-authoritative simulation with client prediction.
- Smooth reconciliation via rollback buffer (~1.5s / ~90 frames default).
- NTP-like clock sync between client and server.
- Rollback-compatible state replication via `ReconcilableNetworkedState`.
- Network condition simulator for testing under loss/jitter/latency.
- Three transports: ENet (UDP, default), WebSocket (TCP fallback),
  WebRTC DataChannels (UDP semantics in browser).

## Consuming

Add as a git submodule from your game repo:

```bash
git submodule add \
    https://github.com/SnoringCatGames/godot-rollback-netcode \
    third_party/godot-rollback-netcode
ln -s ../third_party/godot-rollback-netcode/addons/rollback_netcode \
    addons/rollback_netcode
```

Pin to a specific tag (`v1.0.0`, etc.) for stability.

## Versioning

Independent semver. Decoupled from `snoringcat-platform`.

## Sibling repos

- [snoringcat-platform](https://github.com/SnoringCatGames/snoringcat-platform)
- [godot-gamelift-session-manager](https://github.com/SnoringCatGames/godot-gamelift-session-manager)

## License

TBD before first stable release.
