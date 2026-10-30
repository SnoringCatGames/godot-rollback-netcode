# Ledger done

Done items moved out of `LEDGER.md` by `ledger.mjs archive` (claude-config
`tools/ledger.mjs`, CC65), verbatim, under their ID. New entries go at the
bottom.

## RN4 (Done 2026-10-11)

- **RN4** · Every game process exited with 0xC0000005, because
  `PerfTracker._register_custom_monitors()` never removed its 26
  `Performance` monitors. Done in 10b2b09 (1.0.2, 2026-10-11).

## RN5 (Done 2026-10-12)

- **RN5** · The CI parse check opened an example project that never
  loaded an addon script, so it could not fail. Done in 10b2f41
  (2026-10-12); proven to fail on five kinds of breakage.

## RN6 (Done 2026-10-14)

- **RN6** · 3 `test_webrtc_signaling.gd` failures. Fixed:
  `parse_message` now uses instance JSON parsing so malformed
  peer input no longer logs engine errors, and the send-rate
  test asserts the addon default (20 Hz) instead of the host
  project's live settings. All 9 netcode test files pass
  (2026-10-14). Unblocks RN3.

## RN9 (Done 2026-10-20)

- **RN9** · Dropped `ClientSession.auth_display_names`; hopnbop no longer broadcasts account names (H59, bunny names only). Done in b98d490 (2026-10-20).
