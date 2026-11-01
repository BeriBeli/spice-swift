# Current implementation and validation status

Reviewed against the working tree on 2026-11-01. `VERSION` identifies **0.4.4**;
the JPEG/MJPEG Neon backend, stream-feedback and display-layout work below are **unreleased**.
Validation results are dated by implementation task; historical test counts
describe those runs rather than the current package.

For setup, use the [README](../README.md). Stable design rules live in
[ARCHITECTURE.md](ARCHITECTURE.md). This page records implementation and known
validation limits; it is not a queue of inherited development tasks.

## Swift production core (2026-11-01)

The `SwiftSpice` product uses `Sources/SwiftSpice` and the Swift protocol,
transport, channel, codec and renderer targets. Viewer offline rendering uses
`SurfaceStore`; the probe reuses the package's input exercise plan. The Zig
core and its Swift bindings are maintained separately in `libmaspice`; this
repository contains no duplicate core, artifact, generator mode or validation
pipeline for that implementation.

QUIC remains the spice-gtk C codec. JPEG/MJPEG Neon, Display stream feedback,
dynamic resolution fixes, local benchmarks and the removal of remote campaign
tooling are retained.

Local verification of the restored package passed:

- A fresh warnings-as-errors SwiftPM build of the library, Viewer and Probe,
  plus the standalone public API consumer build.
- All **727** tests, followed by all 727 under AddressSanitizer.
- Protocol generation consistency, C-shim static analysis, native dependency
  closure, and the QUIC C consumer/oracle validation described below.
- Coverage: **80.61%** lines, **82.37%** functions and **72.97%** regions;
  the unchanged 62% line-coverage floor passed.

These are local checks; no new live-peer, physical-screen or remote CI run was
performed for this restoration.

## Dynamic resolution fixes (2026-11-01)

The Swift display-layout coordinator sends the latest monitor layout without
requiring an Agent reply to the previous layout. Unacknowledged overlapping
sends make reply correlation ambiguous until the next Agent connection; late
replies cannot acknowledge or reject the newest size. The viewer accepts an
authoritative Display update without requiring an Agent ACK first, and a later
ACK cannot undo an already applied status.

Regression tests cover coalesced updates, overlapping unacknowledged requests,
late/duplicate replies, reconnect and viewer completion from Display updates.
These are local checks; fresh live-guest resolution acceptance remains separate.

## Toolchain and dependency refresh (2026-10-30)

The package and public API consumer now require Swift tools 6.4. Local checks
used Xcode 27.1 / Apple Swift 6.4 on the M4 Pro host. CI selects the same Xcode
on the `xcode-27` hosted image; that remote CI run has not been performed here.
libjpeg-turbo is now 3.2.1. Current QUIC provenance and validation are recorded
in the spice-gtk C section below.
usbredir 0.15.0, libusb 1.0.30 and the optional benchmark 1.38.1 remain current.
The libusb build disables the SDK 27-only `pipe2` probe to retain macOS 26 support.

- The complete `make all` baseline passed: warnings-as-errors library/public API
  builds, generated-source consistency, C analysis, native closure, all **725**
  current tests, all 725 under AddressSanitizer, and coverage (**80.52%** lines,
  above the unchanged 62% floor). The smaller count than the historical 908-test
  run below reflects the retired remote campaign targets.
- Fresh ASan-instrumented libjpeg-turbo 3.2.1 scalar and Neon builds passed all
  **20** exact-pixel/guard/padding/alpha comparisons.
- Maspice's 55 application tests passed against this local checkout as well as
  the pinned 0.4.4 release. Its latest Sparkle 2.10.1 Release app assembly,
  relocatability audit and ad hoc signature verification passed.

## Production spice-gtk C QUIC (2026-11-01)

`CSpiceQUIC.xcframework` is rebuilt from the checksum-verified spice-gtk 0.42
archive and its unchanged spice-common C codec. The bounded BGRA bridge,
grayscale cleanup fix and top-down orientation remain.

Current C ABI/sanitizer checks live in `Tests/CSpiceQUICTests` and run through
`Scripts/validate-quic.sh`, `make all` and CI. The archive records upstream and
owned-source provenance.

Local verification passed:

- QUIC artifact rebuild, source/binary/header provenance, native dependency
  closure and C static analysis.
- **864** native C pixel/guard cases and **96** allocation-failure trials,
  plus streaming/callback/cleanup checks. ASan/UBSan cover the consumer and
  independent source-built C oracle; the shipped archive is not instrumented.
- All **5** QUIC decoder/Display regression tests passed under Swift ASan,
  including logical row order and malformed-input Surface rollback.

These are local artifact/application checks; no new live-peer, physical-screen
or release acceptance is implied.

## Feature evidence

| Area | Recorded evidence | Still pending |
| --- | --- | --- |
| Main, TCP/TLS, ticket authentication, Display, Cursor, Inputs | Local tests and live QEMU/SPICE desktop and trusted-TLS checks | Fresh peer checks use an externally supplied SPICE endpoint |
| JPEG, LZ, GLZ, ZLIB-GLZ, QUIC, MJPEG | Bounded decoders, independent golden fixtures, transactional Surface tests; latest JPEG and feedback evidence below | Installed-app QUIC orientation check and actual-session MJPEG quality/latency validation |
| H.264/H.265 | Explicit opt-in VideoToolbox decode and Rocky yuv420p native-Metal interoperability on M4 Pro | Broader profiles/resolutions and real-window hardware matrix; MJPEG remains the default |
| IOSurface/Metal desktop | Revisioned publication, bounded native composition, focused tests and M4 Pro window evidence | M1, real 1080p/4K, fixed 60 Hz/ProMotion, resize/occlusion and fresh comparative performance |
| Agent | Rich-guest clipboard, file transfer and monitor-layout checks | Fresh peer validation requires a guest with Agent support |
| Playback/Record | Local protocol, preallocated rings and deterministic host-adapter tests | Audible playback, route switching and physical microphone capture |
| WebDAV | Earlier Rocky direct GET and davfs2 mount/read evidence; bounded executor changes tested locally | The executor path has not been revalidated against a live guest |
| Smartcard, USB, migration | Local protocol/state-machine tests | Real devices and live semi-seamless/seamless migration |
| Distribution | Recorded arm64 packaging, closure and ad hoc signing checks | Developer ID, notarization, Gatekeeper and a clean Apple Silicon macOS 26 host |

Local implementation, deterministic tests, live interoperability, hardware
validation, and performance measurements are separate claims. A passing result
for an earlier implementation does not verify every subsequent release.

## Local performance tooling

The opt-in `SpiceBenchmarks` executable replaces remote benchmark orchestration
with fixed local codec, wire, protocol, and Surface workloads. See the
[benchmark guide](../Benchmarks/BENCHMARKS.md) for measurement boundaries and
same-machine baseline comparisons. `spice-probe`, viewer presentation diagnostics,
and local frame-correlation tests remain available for live-session investigation.
Local timings do not establish end-to-end interaction latency or peer interoperability.

## JPEG/MJPEG Neon backend (2026-10-30)

The first follow-up batch to the 0.4.4 source comparison enables and requires
libjpeg-turbo 3.2.0's arm64 Neon backend. The historical `WITH_SIMD=OFF` setting
has no recorded failure rationale; the current arm64-only target builds the
upstream intrinsics without NASM/Yasm. Source version/checksum, quality flags,
headers, license and minimum macOS 26.0 target are unchanged. QUIC and USB
artifacts, stream scheduling, generation/order checks and Surface mutation
barriers are unchanged. The preceding STREAM_REPORT work is preserved.

The native build now supports `--jpeg-only`, pins upstream's date-dependent
build string, normalizes archive timestamps/uid/gid and records source,
compiler/SDK/configuration and archive SHA-256. Independent build directories
produced byte-identical artifact files/symlinks. Closure checks verify the hash
and exact-quality Neon kernels; an isolated replacement with the old scalar
archive was rejected. See [the complete source investigation, raw measurements
and reproduction commands](../Benchmarks/NativeJPEG/README.md).

Validation completed:

- Warnings-as-errors build and all **908 serial tests** passed. The expanded
  MJPEG golden test exercises all six fixtures through IOSurface and forced
  Data paths, including CMYK, grayscale, progressive and ICC-bearing data,
  with a reused handle across format/geometry changes.
- The first full run had one untouched Remote Rocky script fixture timeout
  while other native checks were running. A subsequent complete serial run
  without those overlapping checks passed; no timeout or assertion was weakened.
- `Scripts/test-address-sanitizer.sh` passed all **908 tests**. Separately, fresh
  fully ASan-instrumented scalar/Neon native libraries and the C harness passed
  all **20** small/odd/1080p/4K format comparisons, guard, row-padding and alpha
  checks. These are distinct sanitizer boundaries.
- The shipped Release archive matched the scalar baseline byte-for-byte for
  all 20 synthetic cases. The separate upstream Neon Release build passed
  **332/332** CTest tests.
- `Scripts/build-lib.sh`, C-shim static analysis, standalone harness static
  analysis, native closure, and protocol generation consistency checks passed.
- On the measured M4 Pro host (macOS 27.2, Clang 21.0.0, SDK 27.0), quality-80
  4:2:0 full-frame decoding used median **7.436 → 4.304 CPU ms/frame** at
  1920×1080 and **30.208 → 17.594 CPU ms/frame** at 3840×2160. Five alternating
  trials each decoded 30 complete frames after warmup; exact same encoded
  inputs, accurate inverse DCT and fancy upsampling were used for both builds.
  Raw CPU/wall times, frame counts and image/artifact hashes are retained.

These are local codec results, not user-session latency, displayed FPS or
spice-gtk comparison claims. Actual-server quality recovery, M1 and real-window
1080p/4K validation remain pending. No installed Maspice application was
replaced/launched, and the current remote desktop was not operated or
reconnected. No push, tag or release was made. Drawing/RAW/cursor compatibility,
motion ACK flow control and codec-policy visibility remain later scoped work.

## Display stream feedback correction (2026-10-30)

SwiftSpice now advertises and implements `STREAM_REPORT`, following spice-gtk
0.43 arrival-margin accounting. See [the comparison](STREAM_FEEDBACK.md) for the
protocol contract and the spice-server 0.15.2 rate-control path that otherwise
cannot receive positive recovery feedback.

Validation completed:

- All 908 tests passed with `swift test --disable-sandbox --no-parallel
  -Xswiftc -warnings-as-errors`, including the existing admitted-late-frame,
  frame-order and Surface mutation-barrier regressions. The first parallel run
  encountered timeout failures in untouched filesystem/WebDAV and remote-script
  fixture tests; the repository CI/release serial invocation passed in full.
- Warnings-as-errors build and protocol generation consistency check passed.
- A task-isolated Linux container built the official spice-server 0.15.2
  `server/tests/test-display-streaming` peer. The built `spice-probe` connected
  over a loopback-only listener; the installed Maspice session was not used.
- The unmodified streaming scenario accepted feedback and the probe exited
  successfully after 25 seconds. A second 35-second scenario set the fixture's
  `sized` flag to 1 and `test->wakeup_ms` to 40 to extend continuous video.
  Both used `SPICE_BIT_RATE=1`, a low initial bandwidth estimate rather than
  an imposed network rate limit; the server encoder/feedback code was unmodified.
- In the extended scenario, the peer accepted 54 reports covering 270 arrivals,
  with zero reported late arrivals and no report-ID mismatch. It logged 12
  bitrate increases, from an initial stream allocation of 0.80 Mbps to 1.92
  Mbps. JPEG quality evaluation fell to 20 and ultimately selected 80.
  The client recorded 96 native video compositions and zero GPU errors, then
  disconnected successfully. This is protocol/rate-recovery evidence, not an
  end-to-end latency benchmark or a comparison against another client.

The remote server's version and reason for its initial quality downshift remain
unknown. Recovery in the user's actual session is still pending a separate test
build. No installed application was replaced, and no release was published.

## Verification entry points

[README build and test instructions](../README.md#build-and-test), the
[Makefile](../Makefile), and [CI workflow](../.github/workflows/ci.yml) define the
current local checks. `make all` runs the aggregate gate, including the public
API consumer, serial tests, C analysis, AddressSanitizer and coverage.

Performance and native dependency checks are documented separately:

- [Local benchmark suite](../Benchmarks/BENCHMARKS.md)
- [Native artifact provenance](../Artifacts/NATIVE_DEPENDENCIES.md)

Live validation uses an externally configured endpoint with `spice-probe` or
the actual client. Earlier passing runs do not prove current host or peer behavior.
