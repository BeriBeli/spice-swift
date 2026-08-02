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

## External acceptance gates

- Validate M1 and real-window 1080p/4K rendering at fixed 60 Hz and ProMotion,
  including resize and occlusion behavior. The current M4 Pro and Rocky yuv420p
  H.264/H.265 native-Metal gate is closed.
- Close audible Playback and physical microphone Record behavior.
- Validate real Smartcard and redirected USB devices.
- Exercise live semi-seamless and seamless migration.
- Make the signal-reset guest fixture activity-valid for 20/20 short 4K stress
  samples, then rerun fresh ten-pair, 30-second CPU and Metal batches at both
  1280x720 and 3840x2160. The 2026-08-02 formal collection was rejected because
  the old fixture became static in late pairs.
- Reduce CPU per published frame to at most 1.10x spice-client-glib2 while
  preserving fps, ready-frame, p95, lifecycle, and GPU-evidence gates. The
  current valid eight-pair diagnostic ratios range from 1.375421 to 1.944140;
  4K Metal must also reduce its 1.256189 RSS ratio to at most 1.15.
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
./Scripts/build-and-run.sh --package
```

The nested QEMU gates have additional host requirements and retained artifacts.
Follow [APPLE_CONTAINER.md](../Integration/AppleContainer/APPLE_CONTAINER.md)
instead of treating them as unit tests.
