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
- Replace or repair the persistent downstream xterm/Xorg fixture path, add X11
  Present/Damage evidence, and require 20/20 activity-valid full-duration
  preflight samples at both 1280x720 and 3840x2160. Then rerun both the
  ten-pair, 30-second `cpu` versus GLib reference and the direct
  `cpu-iosurface` versus `metal` comparison under one epoch, reset, and order
  schedule. The direct runner/analyzer are implemented and were exercised at
  `bb3b176`, but both complete batches were rejected after late downstream
  activity stalls even though guest generator telemetry continued.
- Before production-enabling Metal 2D, eliminate the per-publication full-frame
  seed and serial seed/draw completion waits, preserve partial damage history,
  avoid scratch for non-overlapping COPY_BITS, deduplicate clipped bitmap
  uploads, and bound resident upload/scratch pools.
- Reduce direct Metal CPU per published frame to at most 1.10x
  `cpu-iosurface` while preserving fps, ready-frame, p95, lifecycle, and
  GPU-evidence gates. The activity-valid diagnostic prefixes measured 1.730965
  at 720p and 1.754194 at 4K; 4K Metal must also reduce its 1.340859 RSS ratio
  to at most 1.15. Retain the separate selected-renderer versus GLib reference
  gate rather than combining its samples with the direct A/B.
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
