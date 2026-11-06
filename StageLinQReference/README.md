# StageLinQReference

## Implementation checklist

- [x] Separate normal Xcode macOS app project; no Swift Package Manager.
- [x] Startup mixer-IP configuration and UDP announcement/probe flow.
- [x] Continuous announcement parsing with identity/token-based device tracking.
- [x] Per-player directory negotiation, service-table locking, generation checks.
- [x] Independent StateMap and BeatInfo receive-loop placeholders with frame buffering.
- [x] Raw packet trace, replay decoder mode, diagnostic UI, and XCTest coverage.
- [ ] Live Denon hardware verification (requires configured mixer/player network).

