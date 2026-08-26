# SwiftSpice roadmap

This document lists unfinished work and the checks required before a feature or
release claim is complete. See [STATUS.md](STATUS.md) for current evidence and
[ARCHITECTURE.md](ARCHITECTURE.md) for design rules. The active protocol,
rendering, and ownership work is tracked in the
[algorithm improvement plan](ALGORITHM_IMPROVEMENT_PLAN.md).

## Closed locally

- Wire framing, Link handshake, ticket authentication, and channel attachment
- Strict full-header message lists with owned physical batches, ordered logical
  dispatch, and one ACK unit per physical message
- Basic desktop Display, Cursor, and Inputs paths
- JPEG, LZ, GLZ, ZLIB-GLZ, QUIC, MJPEG, and bounded per-Display image-cache
  behavior; cross-Display Session sharing remains open in AIP-12
- IOSurface and Metal presentation with a CPU frame fallback
- Playback, Record, Agent clipboard, file transfer, and monitor configuration
- Smartcard, USB redirection, WebDAV, and migration state machines
- H.264/H.265 parsing, explicit opt-in negotiation, VideoToolbox decoding, and
  deterministic Rocky yuv420p protocol evidence
- Revisioned Apple Silicon IOSurface backing and native NV12-to-Metal composition
- Full tests without exclusions, security-focused C static analysis,
  AddressSanitizer, and a merged production-source line coverage baseline

## External acceptance gates

- Validate M1 and real-window 1080p/4K rendering at fixed 60 Hz and ProMotion,
  including resize and occlusion behavior. The current M4 Pro and Rocky yuv420p
  H.264/H.265 native-Metal gate is closed.
- Close audible Playback and physical microphone Record behavior.
- Validate real Smartcard and redirected USB devices.
- Exercise live semi-seamless and seamless migration.
- Establish a fresh `v0.2.7` CPU-per-frame baseline before setting a current
  optimization target. The retained 2026-08-01 Rocky result is historical and
  must not be used as current evidence. Preserve the existing fps, ready-frame,
  p95, RSS, and zero-stale gates, then run ten paired 30-second measurements.
- Complete Developer ID signing, notarization, Gatekeeper acceptance, and launch
  on a clean Apple Silicon macOS 26 host.
- Restore the custom KVM kernel and local QEMU image before rerunning the current
  Apple/container gate.

## Extension rules

New work must meet these conditions:

1. Add strict wire parsing and negative tests before enabling a message path.
2. Bound memory, queues, caches, and retained continuations.
3. Keep failed operations transactional at their public state boundary.
4. Add an independent fixture or live peer check for codec and protocol claims.
5. Advertise a capability only after the implementation and its required
   interoperability gate are complete.

## Acceptance commands

```sh
swift build --disable-sandbox -Xswiftc -warnings-as-errors
swift test --disable-sandbox -Xswiftc -warnings-as-errors
swift package --allow-writing-to-package-directory generate-spice-protocol --check
./Scripts/build-lib.sh
./Scripts/analyze-c-shims.sh
./Scripts/test-address-sanitizer.sh
./Scripts/check-code-coverage.sh
```

The nested QEMU gates have additional host requirements and retained artifacts.
Follow [APPLE_CONTAINER.md](../Integration/AppleContainer/APPLE_CONTAINER.md)
instead of treating them as unit tests.
