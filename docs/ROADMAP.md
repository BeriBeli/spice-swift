# SwiftSpice roadmap

This document lists unfinished work and the checks required before a feature or
release claim is complete. See [STATUS.md](STATUS.md) for current evidence and
[ARCHITECTURE.md](ARCHITECTURE.md) for design rules.

## Closed locally

- Wire framing, Link handshake, ticket authentication, and channel attachment
- Basic desktop Display, Cursor, and Inputs paths
- JPEG, LZ, GLZ, ZLIB-GLZ, QUIC, MJPEG, and shared image caches
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
- Reduce the corrected five-second CPU-per-frame ratio from the current
  1.203073 to at most 1.10 while preserving the passing fps, ready-frame, p95,
  RSS, and zero-stale Publisher results. Only then run ten paired 30-second
  bootstrap measurements.
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
