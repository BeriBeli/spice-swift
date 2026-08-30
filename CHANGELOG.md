# Changelog

All notable changes to SwiftSpice are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.3.4] — 2026-08-30

### Added

- Added a deterministic live click/key/motion cluster and paired-artifact
  evaluator. The evaluator accepts only the complete counterbalanced
  10-cluster, two-version, 60-record matrix, reports Hyndman-Fan type-7 p50/p95
  and same-cluster signed deltas, and keeps CPU/RSS as independent guardrails.

### Changed

- Publish the guest binary-grid marker atomically with one `XPutImage`, and
  serialize each live action behind the preceding exact presentation and
  remote collector acknowledgment.
- Allow the foreground measurement harness one pre-arm authoritative-latest
  request when a visible post-baseline Metal commit still has no presentation
  after exactly 250 ms. Readiness still requires a real presented callback and
  retains the original fail-closed timeout.

### Fixed

- Treat `CAMetalDrawable.presentedTime == 0` as a dropped drawable and permit
  only one authoritative latest-only recovery for that selected revision,
  without idle commits or exceeding the existing GPU in-flight bound.
- Keep markerless retries out of the active target trace, preserve the
  selected and committed identity through recovery, and apply
  pointer-mode-aware motion ACK requirements so absolute tablet motion does not
  wait for a relative-motion protocol acknowledgment.

### Validation

- Live Rocky evidence closes exact current-version click/key/motion marker to
  presented-callback correlation, and deterministic tests close the paired
  artifact admission rules. The required adjacent `v0.2.7`/current 10-cluster
  artifact is still pending, so this release makes no AIP-00 completion or
  interaction-latency improvement claim.

## [0.3.3] — 2026-08-29

### Changed

- Replaced realtime playback and capture packet handoffs with fixed-capacity
  preallocated rings. Playback now pulls published PCM without callback-side
  packet allocation, while capture reuses bounded conversion storage and
  materializes wire `Data` only on the async sender side.
- Moved native WebDAV filesystem operations from the Session event path to a
  width-two Swift task executor. Per-client filesystem and response ordering is
  preserved, while unrelated clients can make progress independently under
  explicit pending-job and retained-byte limits.

### Fixed

- Kept audio overflow replacement, startup gating, close/reset, and staged
  publication atomic without copying packet payload under the realtime render
  gate. Queue duration, byte storage, metadata slots, and staging ownership now
  have explicit checked limits.
- Kept WebDAV close, response failure, cancellation, and same-client-ID reuse
  generation-safe even when a synchronous filesystem operation cannot be
  preempted or a response sender is suspended. Late results and queued suffixes
  are suppressed with exactly-once accounting. `HEAD` now reads metadata only
  while preserving exact `Content-Length`; depth-one `PROPFIND` lazily enforces
  its response limit and a 4,096-child metadata cap. The existing public
  synchronous API remains available.

### Validation

- AIP-42 and AIP-43 close deterministic ownership, movement, concurrency, and
  retention gates only. This release makes no measured audio/device-performance,
  WebDAV-throughput, or live-interoperability claim; real audio and WebDAV
  behavior remains part of the AIP-90 live gates.

## [0.3.2] — 2026-08-29

### Added

- Added a foreground AppKit interaction harness that arms only after a visible
  desktop subscription and initial Metal presentation, then correlates one
  guest marker with its exact SwiftSpice delivery and presented callback.

### Fixed

- Bounded live-harness stdout and stderr collection and placed each spawned
  command in an isolated process group, so timeout, inherited pipe writers,
  and excessive output fail closed without leaving descendants behind.

### Validation

- The isolated Rocky live gate remains blocked before arm because the current
  Mac WindowServer session reports the harness window as occluded. No completed
  input-to-visible latency or pacing-improvement claim is made.

## [0.3.1] — 2026-08-29

### Added

- Added versioned guest manifests, verified artifact hashes, and private
  per-run evidence to the existing Rocky 9 rootless Podman/KVM fixture.
- Added a per-event causal input trace schema and private JSONL artifact, plus
  unique guest markers for click, key, and motion probes.

### Changed

- `SpicePresentationMetrics.desktopReadyToDisplayLink` and the corresponding
  session diagnostic now measure from the ready timestamp of the latest
  accepted revision that is actually selected, rather than the first update in
  its coalescing window. This differs from the 0.3.0 metric semantics, so the
  values should not be treated as directly equivalent; latest-only pacing and
  idle no-commit behavior are unchanged.
- Reframed performance work around paired interaction latency first: separate
  input-to-guest and receive-to-presented segments before clarity, with CPU and
  RSS retained as guardrails rather than substitutes for latency acceptance.
- Guest input probes now use a native XI2 source that publishes readiness only
  after event selection and an X server round trip. Source rotation, serialized
  motion epochs, and bounded terminal resynchronization prevent stale input or
  terminal responses from validating a later marker.

### Fixed

- Rejected duplicate unsolicited desktop delivery identities without changing
  their selected-ready timestamp or re-waking presentation, while explicit
  authoritative redraw requests receive a fresh delivery identity.
- Hardened the Rocky fixture against concurrent start/stop/build races, stale
  or reused PIDs, partial artifact publication, incomplete manifests, and
  teardown failures that would otherwise erase auditable active state.

### Validation

- Rocky live runs close the guest-causal input-to-marker draw/ACK subpath only.
  They do not yet bind marker pixels to an exact SwiftSpice frame delivery and
  AppKit presented callback, and therefore make no completed input-to-visible
  latency or performance-improvement claim.

## [0.3.0] — 2026-08-28

### Added

- Added strict full-header physical-message batches with validated submessage
  lists, shared owned storage, ordered logical delivery, and one ACK accounting
  unit per physical message.
- Added a bounded Session-owned image cache for cross-Display references, with
  ordered same-ID mutations, invalidation-safe asynchronous decode, and explicit
  waiter and retained-byte limits.
- Added a bounded canonical `PixelRegion` and deterministic region limits for
  clipped display commands.

### Changed

- Serial barriers now complete after handler and protocol-ACK processing, and
  connection replacement keeps failure, cancellation, Agent sends, and
  migration cleanup bound to the connection that produced the work.
- Display mutations now validate and commit each wire draw as one transaction.
  COPY_BITS avoids area-sized staging, fill uses a bulk C kernel, and eligible
  CPU updates preserve IOSurface-canonical backing and publication damage.
- Framing and parsing now use segmented receive storage, checked owned slices,
  and synchronous Swift `Span` views, avoiding repeated compaction and bounding
  retained owners and segment metadata.
- LZ, GLZ, and stateless codecs now use bounded work admission and explicit
  immutable ownership. LZ decodes into one output backing, while GLZ separates
  dependency coordination from CPU execution.
- Annex-B input is scanned once into checked ranges, and VideoToolbox lends
  CoreMedia one stable owner without redundant payload materialization.
- Initial and migration child-channel connections now use deterministic bounded
  concurrency with complete rollback of early and late successes.

### Validation

- The included AIP-10, AIP-11, AIP-12, AIP-20 through AIP-23, AIP-30 through
  AIP-33, and AIP-40 changes passed their documented Swift 6 focused gates and
  Apple Silicon SwiftPM CI. This release makes no new live SPICE
  interoperability or performance claim: AIP-00, AIP-41 through AIP-43, and
  AIP-90 remain pending or blocked on their recorded gates.

## [0.2.7] — 2026-08-26

### Performance

- Apple Silicon BGRA alpha copies now use contiguous NEON loads and an alpha
  byte mask instead of channel deinterleave/reinterleave operations. Opaque raw
  bitmap uploads also use a dedicated NEON kernel instead of a Swift per-pixel
  loop.

## [0.2.6] — 2026-08-26

### Performance

- Sparse desktop updates now select their latest revision immediately when the
  display link is idle, while one active tick remains as a pacing fence for
  continuous producers. This removes a redundant refresh-period wait without
  allowing presentation work to outrun the display.

## [0.2.5] — 2026-08-26

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

[Unreleased]: https://github.com/BeriBeli/spice-swift/compare/v0.3.4...HEAD
[0.3.4]: https://github.com/BeriBeli/spice-swift/compare/v0.3.3...v0.3.4
[0.3.3]: https://github.com/BeriBeli/spice-swift/compare/v0.3.2...v0.3.3
[0.3.2]: https://github.com/BeriBeli/spice-swift/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/BeriBeli/spice-swift/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/BeriBeli/spice-swift/compare/v0.2.7...v0.3.0
[0.2.7]: https://github.com/BeriBeli/spice-swift/compare/v0.2.6...v0.2.7
[0.2.6]: https://github.com/BeriBeli/spice-swift/compare/v0.2.5...v0.2.6
[0.2.5]: https://github.com/BeriBeli/spice-swift/compare/v0.2.4...v0.2.5
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
