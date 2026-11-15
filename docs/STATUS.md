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

### Real-session performance tool (2026-11-13)

`spice-session-benchmark` adds direct TCP/TLS endpoint and `.vv` connections,
headless or production-view observation, process CPU/high-water memory snapshots,
and structured JSON diagnostics. Opt-in synthetic keyboard capture reuses the
existing exact marker/delivery/Metal-presented trace and atomic JSONL writer.
The standalone browser fixture embeds guest-clock timing in an additional grid;
no host/guest clock synchronization or telemetry server is required. See the
[session guide](../Benchmarks/Session/README.md) for setup and measurement limits.

Local warnings-as-errors validation passed all **737** tests. The **45** focused
benchmark and interaction tests also passed AddressSanitizer, including decoding
the independent JavaScript guest marker into a valid correlated trace and
rejecting truncated, mismatched or non-monotonic embedded guest evidence.
A user-supplied direct TLS `.vv` with custom CA and complete subject validation
successfully connected and observed a real 1920×1080 desktop for ten seconds.
A subsequent five-second visible-window check with the layer-backed AppKit host
recorded **1** confirmed Metal-presented frame and **0** CPU fallback frames.
These were Debug smoke checks on a mostly static desktop, not comparative
performance measurements.

The report distinguishes confirmed Metal presentation, CPU fallback and
`no_confirmed_presentation` explicitly. Live marker-to-presented capture uses
the guest fixture. These local tests and connection/presentation smoke checks
alone do not establish interaction latency or a performance improvement.

### Drawable latency investigation (2026-11-13)

The subsequent Release marker campaign on M4 Pro and a 1920×1080 Linux desktop
produced two complete 200-sample runs and three incomplete runs. One incomplete
run recorded a **1,007.6 ms** selection-to-commit interval followed by no accepted
drawable presentation. Its aggregate timing did not separate preparation,
drawable acquisition and encoding; the historical cause remains unconfirmed.

A follow-up investigation completed **1,200/1,200** measured samples in six
runs: three temporary stage-probe runs with 100 warmup inputs, two byte-identical
original-binary controls and one bounded-metrics run with 50 warmup inputs.
Each run used 200 measured inputs, a 100 ms post-transaction interval, the same
1920×1080 guest, and a 1024×768-point production-view host at backing scale 2.
The one-second stall did not recur in either the original binary or the
instrumented builds. The bounded-metrics run's drawable acquisition maximum,
including readiness and warmup, was **17.16 ms**. ProMotion remained enabled;
the reported 120 Hz maximum is not a fixed measured display cadence.

Presentation diagnostics now split preparation, the `currentDrawable` getter,
encoding/presentation scheduling, and the synchronous `commit()` call into
separate bounded histograms, exported by the session benchmark. Release
warnings-as-errors compilation and the complete **737** tests passed. Rendering
behavior is unchanged. A runtime root-cause fix and its before/after validation
remain pending a reproduced stall with component timing and process-stack
evidence; no performance improvement is claimed.

### Four follow-up measurements (2026-11-13)

The [follow-up report](PERFORMANCE_FOLLOWUP_2026-11-13.md) records current 3.2.1
JPEG cost/quality, finite GPU measurements, controlled source-pixel exports and
actual Maspice input under shaped transport. The settled live reference pixels
matched the generator exactly below the HUD. Two motion variants under both
codec policies produced desktop updates with **zero video decodes**, leaving
live MJPEG/H.264 quality recovery unvalidated.

The shipped decoder used median 4.083 / 16.720 CPU ms per quality-80 4:2:0 frame
at 1080p / 4K. The finite GPU tool measured a 33,177,600-byte revision copy for a
64×64 partial native video update on a retained 4K surface; composition p50 was
1.338 ms. These are operation costs with retained correctness checks, not a
runtime optimization or a diagnosis of the historical one-second stall.

The installed Maspice 0.6.1 completed forty real Space presses in each of three
profiles: unrestricted, 50±20 ms each direction with 20 Mbit/s, and 25±10 ms with
2 Mbit/s. All final guest counters were forty; input FIFO peak was two and send
failures were zero. Low bandwidth delayed visual echo after the local queue had
emptied. Actual-viewer per-key presentation latency remains unmeasured.

Opt-in fixture transfer, post-window PNG export, quality/pipeline tools and a
bounded loopback shaper make these checks repeatable. Release warnings-as-errors
builds, all **741** package tests, four fixture tests under AddressSanitizer, and
the relay integration check passed. No production rendering/input behavior or
installed application was changed. The original marker/session was restored.

### Visible-window measurements and server findings (2026-11-14)

The [visible-window report](PERFORMANCE_VISIBLE_2026-11-14.md) adds actual Maspice
copy/traffic diagnostics and fullscreen MP4 playback. Forty marker presses were
all visible. The 30 FPS playback observation received approximately 86.7 Mbit/s
of Display read data, using QUIC/LZ desktop drawing with zero stream creation
and video decoding. Drawable acquisition did not reproduce the historical
one-second stall. SwiftSpice's **743** tests and Maspice's **57** tests passed;
the installed app was preserved and the original marker restored.

Subsequent **user-reported** remote inspection found direct QEMU startup without
`streaming-video` (documented default `off`), and a SPICE library accepting native
MJPEG but rejecting the GStreamer H.264 encoder. This explains the video-path
setup limitation. At that record's cutoff, the MJPEG comparison and independent
server version/hash collection were still pending. H.264 needs a server
encoder/build change first; the historical one-second stall remains unresolved.

### Actual-server MJPEG comparison and admission correction (2026-11-14)

The [actual-server comparison](PERFORMANCE_MJPEG_AB_2026-11-14.md) independently
confirmed QEMU 11.1.2, SPICE package 0.16.0-4, original default-off arguments and
binary hashes. Graceful Linux Lite restarts compared `all`, `filter` and `off`
with the same corrected Release client; the other VM and TLS relay stayed running.
All three marker checks passed forty real inputs, **120/120** total.

A full-field fixture triggered 50 MJPEG streams. Before the correction, minor
negative multimedia margins discarded 4,988 of 5,558 frames before decode despite
no synchronized playback anchor. MJPEG now bypasses that deadline when there is
no playback anchor, preserving active-audio scheduling and bounded replacement.
The final `all` window decoded 22,970/22,970 received fragments directly into
IOSurface, with zero such clock drops. SwiftSpice's **744** tests, Maspice's **57**
tests, the Release app build, native closure and signature verification passed.

The synthetic full-field workload received about 52.6 / 15.4 / 13.6 Mbit/s under
`off` / `all` / `filter`, but canonical GPU copy traffic was 0.71 / 3.07 / 2.80 GiB/s.
Streaming still showed vertical phase bands, and native composition counts lagged
decode counts. Multi-stream region ordering, rejection attribution and full-Surface
copy amplification remain open. These are not complete-frame FPS, codec-quality
or per-key latency results. Keep default `off`; the historical one-second drawable
stall was not reproduced or explained. Server defaults, the installed client and
fullscreen marker at zero were restored; no release was published.

### MJPEG disjoint-region ordering correction (2026-11-14)

The [region-ordering follow-up](PERFORMANCE_MJPEG_REGIONS_2026-11-14.md) reproduced
two client fragment-loss cases: a newer video commit or desktop command on one
region invalidated a delayed video frame on a disjoint region. Bounded coverage
records now permit disjoint writes while preserving overlapping wire order,
desktop overwrite protection, lifecycle checks and transactional GPU ownership.

All **749** SwiftSpice tests passed normally and under Address Sanitizer; all
**57** Maspice tests and its Release build/closure/signature checks passed.
The subsequent [live A/B/A comparison](PERFORMANCE_MJPEG_REGIONS_LIVE_2026-11-14.md)
used the preserved control and corrected Release builds on the same running VM
under `all`. Native commits/decoded fragments were **66.2% / 99.4% / 69.0%**;
narrow phase strips diminished in the corrected observations and reappeared on
return to the control. Broader boundaries and the residual commit gap remain.

Canonical copy traffic was **4.15 / 8.16 / 4.25 GiB/s**, with a full 8,294,400-byte
Surface per counted copy. Pool exhaustion/readbacks also increased in the
corrected window. Forty marker inputs per A/B build passed, **80/80** total;
no per-key presented-latency gain or complete-frame FPS is established. The
historical one-second stall remains unexplained. Keep the correctness fix and
prioritize bounded composition/candidate-copy work next. Default `off`, the
installed viewer and fullscreen marker at zero were restored; no release was
published. No new production edits or test runs occurred during this live check.

### MJPEG incremental candidate copies (2026-11-14)

The [candidate-copy follow-up](PERFORMANCE_MJPEG_COPY_2026-11-14.md) reuses the
bounded revision damage history for GPU region catch-up. Unknown, expired and
aborted candidates retain full repair. Native commits include pending CPU damage;
published snapshots remain immutable. All **752** SwiftSpice tests passed normally
and under ASan; Maspice's **57** tests and Release closure/signature checks passed.

Real A/B/A on the same running VM under `all` reduced mean copy bytes **82.3%**,
from **8,294,400** to **1,469,794**. Accounted copy traffic was **6.50 / 1.08 / 5.59
GiB/s**, and mean copy wait **0.601 / 0.485 / 0.702 ms**. Native commits remained
**98.94% / 98.73% / 99.17%** of decoded fragments; forty marker inputs per A/B
build passed. GPU errors remained zero.

Overall performance acceptance remains pending: client CPU was **70.95% / 81.81%
/ 74.33%** of one core, with different fragment/presentation rates and higher
candidate-window pool/readback pressure. No CPU or per-key latency improvement
is established. Keep the implementation unreleased and server default `off`;
profile CPU and reduce repeated fragment synchronization next. The historical
one-second stall remains unexplained. Default server startup, the original
installed viewer and fullscreen marker at zero were restored; no release was
published. Earlier reports and archives remain unchanged.

### MJPEG bounded ready batches (2026-11-14)

The [ready-batch follow-up](PERFORMANCE_MJPEG_BATCH_2026-11-14.md) combines at
most eight already-decoded native MJPEG draws into one Surface transaction,
sharing candidate catch-up, composition completion and one publication request.
It adds no timer or wait for missing streams. Per-member clip, lifecycle,
desktop-barrier and overlapping wire-order validation remains; failure publishes
neither accepted pixels nor staged guards. Snapshot immutability and close/drain
ownership are covered by tests. All **755** SwiftSpice tests passed normally and
under ASan; **57** Maspice tests and Release closure/signature checks passed.

Real A/B on the same running VM under `all`, with bounded sixty-second CPU
windows, measured **85.55% → 71.95%** client CPU on a one-core basis. Per accepted
native fragment, synchronization requests fell **76.09%** and mutation submission
requests **64.00%**. Copy wait per observation second fell **51.85%**; QEMU CPU
remained about **55.8%**. Both builds delivered forty real marker inputs and
recorded zero GPU errors. Native counters continue counting fragments, while
accepted batches share one revision; timing population and pool-checkout
granularity differ from the control.

This single pair supports the direction, without general latency or hardware
acceptance. Readbacks rose **2.93 → 4.48/s**, and approximate native acceptance
fell **97.67% → 96.49%**; these remain the next bottleneck to investigate.
Keep the change unreleased and server default `off`. The historical one-second
stall remains unexplained. Default server startup, original installed viewer
and fullscreen marker at zero were restored. Prior reports/archives are unchanged.

### Native candidate lease recovery (2026-11-14)

The [readback follow-up](PERFORMANCE_MJPEG_READBACK_2026-11-14.md) identifies
temporary candidate ownership and per-member batch fallback as a material source
of readback/native losses. A matching non-source consumer lease can now release
before a 16 ms admission deadline; cancellation, retirement, timeout and permanent
capacity retain bounded cleanup/fallback. The ring and budget are unchanged.
Both builds expose native fallback fragments and batch recovery counters.

Real A/B on the same running VM under `all` measured **1.96 → 0.91 readbacks/s**
and **98.26% → 99.22%** approximate native acceptance. B recovered **91 of 168**
checkout attempts; remaining 77 failed checkouts retained CPU fallback. Client
CPU was **64.59% → 56.69%** of one core, with **10.10% fewer delivered fragments/s**;
the CPU saving is not fully attributable to the policy. Both builds delivered
forty real marker inputs and recorded zero GPU errors. All **757** SwiftSpice
tests passed normally/ASan, **57** application tests and Release checks passed.

Vertical color boundaries remain in both builds; cross-stream source/publication
coherence needs separate measurement. The historical one-second stall remains
unexplained. Keep the change unreleased and server default `off`. Original viewer,
default startup and fullscreen marker at zero were restored at this experiment's
endpoint. Prior evidence remains unchanged; separately requested external-client
comparisons are not included in this A/B result.

## Native visible-response supplement (2026-11-15)

The subsequent [Spicy visual check](SPICY_VISUAL_ARTIFACTS_2026-11-15.md)
also observed vertical color discontinuities. Spicy is excluded from performance
ranking. Temporary CocoaSpice/Spicy packages and working window-control tools were
removed at the user's request; reports and archived evidence remain available.

The [real-window supplement](PERFORMANCE_NATIVE_VISIBLE_2026-11-15.md) adds 100
Space and 100 mouse samples per primary client. Both completed without timeout.
Cocoa TLS backport's consistent-region p50 was about 15–18ms lower, while keyboard
p95 was similar (163ms versus Maspice's 162ms). Maspice's observed coded-region
consistency rate was 8.27/s, with mixed states occupying 75.09% of the sampled
window. Cocoa's dynamic code fields failed in three quarters of the image even
at original-resolution capture; complete-image FPS remains unranked, not 0FPS.
This is a new synthetic workload with measured observer overhead, not a conversion
of the earlier CPU result into speed. No product source changed. Original viewer,
fullscreen marker0 and default server mode were restored; prior archives remain.

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
