# Changelog

All notable changes to SwiftSpice are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Added bounded desktop-ready-to-display-link timing diagnostics so frame-clock
  scheduling delay is measured separately from Metal commit and compositor
  presentation latency.

### Performance

- Full-surface raw bitmap copies now write directly into a revisioned IOSurface
  and publish that canonical revision without a second full-frame CPU upload.
- Fractionally scaled desktops use MPS Lanczos directly into the drawable,
  restoring v0.1.x text clarity without an intermediate texture or blit.
- Blocking MJPEG decode work now runs on a per-stream GCD serial executor so
  it cannot starve input and UI jobs on Swift's cooperative executor.
- Display receive now feeds a one-in-flight, one-latest MJPEG mailbox, matching
  spice-gtk's queued decoder scheduling by discarding superseded encoded frames
  before libturbojpeg instead of accumulating visual latency.

### Fixed

- MJPEG streams now preserve libjpeg-turbo's accurate DCT and chroma
  upsampling, matching the static JPEG path instead of blurring colored text.
- Every plain and TLS SPICE channel now uses spice-gtk's TCP keepalive policy,
  preventing an otherwise idle main channel from timing out while display and
  input channels remain active.

## [0.2.4] — 2026-08-25

### Performance

- Vectorized overlapping GLZ alpha-plane expansion with Apple Silicon NEON,
  while retaining a scalar tail and preserving the untouched BGRA color lanes.

## [0.2.3] — 2026-08-25

### Fixed

- Advanced paused `MTKView` presentation through one explicit draw cycle per
  selected desktop revision, preventing reuse of an already-presented
  `CAMetalDrawable`, GPU timeouts, and repeated AppKit CPU fallback.

## [0.2.2] — 2026-08-25

### Added

- Added a revision-backed Agent reconnect-boundary acknowledgement so
  applications can wait for session disconnect cleanup and old connection work
  to drain before reusing a `SpiceSession`, including startup, in-progress
  disconnect, and dequeued-event races.

### Fixed

- Added ordered Agent-disconnected and playback-stopped boundaries before a
  session failure/disconnect, preserving fixed consumers across reconnects.
- Added a bounded Agent mailbox that atomically discards stale payloads at a
  disconnect boundary, preserves ordered lifecycle events across reconnects,
  and permits a consumer to stop and restart without terminating the session.
- Fenced Agent work by lifecycle generation so dequeued messages cannot reply
  after a transport reconnect, migration, or in-place guest Agent restart.
- Serialized complete client Agent messages, reserved their tokens atomically,
  and kept every fragment on one captured Main Channel connection during
  seamless rebinding; a failed partial message now invalidates the byte stream
  before any queued message can write.
- Serialized connection attempts with disconnect cleanup and bound reconnect
  fences to exact session lifecycle IDs, preventing late adoption, actor-hop
  ABA waits, and cancellation or stop leaks.
- Isolated AVAudio completion handlers by playback epoch so a late completion
  from the old connection cannot mutate the new stream's buffer controller.
- Ended the old playback lifecycle before a non-seamless migration adopts its
  target, while leaving seamless channel rebinding uninterrupted.

## [0.2.1] — 2026-08-25

### Added

- Added `advancedVideoPresentedFrames` diagnostics that correlate a native
  H.264/H.265 surface revision with its final CAMetalDrawable presentation.

### Fixed

- Fixed release-app Metal shader discovery by resolving metallib resources
  through their embedded SwiftPM bundles instead of assuming bundle-root files.

## [0.2.0] — 2026-08-25

### Added

- Added the demand-driven `SpiceDesktopSource` subscription API with bounded
  latest-only desktop snapshots, per-subscriber damage, lifecycle generations,
  visibility demand, and unified frame, cursor, and pointer-mode state.
- Added content-free diagnostics for desktop coalescing, suppressed snapshots,
  display-link scheduling, texture reuse, GPU back-pressure, MJPEG allocation,
  and hardware-codec session selection and failure classification.

### Changed

- Replaced frame, surface, cursor, and mouse-mode session events with the
  breaking desktop-source API; display commands now advance canonical surfaces
  independently from snapshot and presentation demand.
- Reworked macOS presentation around one-shot `NSView` display links, explicit
  MTKView draws, cached IOSurface textures, and a single full-screen Metal pass.
- Reused bounded MJPEG decoder and IOSurface resources with stream-only fast
  DCT/upsampling, while retaining bit-exact static JPEG decoding and ordered
  VideoToolbox decoding.
- Strengthened the trusted baseline with exclusion-free tests,
  security-focused C static analysis, AddressSanitizer, and a merged production
  line coverage floor enforced locally, in CI, and before releases.

## [0.1.10] — 2026-08-20

### Changed

- Refined bounded display timing diagnostics with framed-receive, surface-ready,
  publisher, mailbox, and presentation boundaries for locating dropped frames
  without recording display content.

## [0.1.9] — 2026-08-20

### Added

- Added build-environment diagnostics and reusable Mach-O dependency auditing.
- Added dedicated library building, viewer debug-run, version-check, release,
  and Makefile task-runner commands.
- Added version, changelog, and release-tag consistency gates.
- Added bounded, content-free timing summaries across frame publishing,
  session mailbox delivery, and Metal presentation.

### Fixed

- Made an asynchronous transport-close assertion evaluate reliably with the
  Swift 6.4 Testing runtime.
- Made the library build gate target `SwiftSpice` directly and recognize both
  Swift Build and native SwiftPM module layouts.

## [0.1.8] — 2026-08-20

### Fixed

- Packaged native static dependencies as named frameworks so Swift Build no longer collides on shared module-map and header output paths.

## [0.1.7] — 2026-08-20

### Fixed

- Fixed pointer capture and frame presentation behavior.

## [0.1.6] — 2026-08-08

### Added

- Added content-free clipboard failure diagnostics.

## [0.1.5] — 2026-08-08

### Added

- Exposed Agent wire diagnostics.

## [0.1.4] — 2026-08-08

### Added

- Exposed session diagnostics snapshots.

## [0.1.3] — 2026-08-02

### Fixed

- Fixed SPICE client/server mouse-mode negotiation.

## [0.1.2] — 2026-08-01

### Fixed

- Fixed cursor caching, duplicate cursor presentation, and Retina scaling edges.

## [0.1.1] — 2026-08-01

### Fixed

- Fixed validation of legacy SPICE TLS certificates.

## [0.1.0] — 2026-08-01

### Added

- Published the initial native Swift SPICE client library, viewer, probe, protocol codecs, and checked-in native dependencies.

[Unreleased]: https://github.com/BeriBeli/spice-swift/compare/v0.2.4...HEAD
[0.2.4]: https://github.com/BeriBeli/spice-swift/compare/v0.2.3...v0.2.4
[0.2.3]: https://github.com/BeriBeli/spice-swift/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/BeriBeli/spice-swift/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/BeriBeli/spice-swift/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/BeriBeli/spice-swift/compare/v0.1.10...v0.2.0
[0.1.10]: https://github.com/BeriBeli/spice-swift/compare/v0.1.9...v0.1.10
[0.1.9]: https://github.com/BeriBeli/spice-swift/compare/v0.1.8...v0.1.9
[0.1.8]: https://github.com/BeriBeli/spice-swift/compare/v0.1.7...v0.1.8
[0.1.7]: https://github.com/BeriBeli/spice-swift/compare/v0.1.6...v0.1.7
[0.1.6]: https://github.com/BeriBeli/spice-swift/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/BeriBeli/spice-swift/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/BeriBeli/spice-swift/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/BeriBeli/spice-swift/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/BeriBeli/spice-swift/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/BeriBeli/spice-swift/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/BeriBeli/spice-swift/releases/tag/v0.1.0
