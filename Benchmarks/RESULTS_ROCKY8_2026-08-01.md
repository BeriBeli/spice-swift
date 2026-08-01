# SwiftSpice and spice-client-glib2 remote performance results

Test date: 2026-08-01 (Asia/Singapore)

This report keeps the latest measurements first. The later sections preserve
the original failing baseline and the evidence that led to subsequent fixes.

## Post-publisher revision-race smoke (16:20)

The current dirty working tree was rebuilt as an arm64 Release `spice-probe`
after repairing publisher revision races and removing the per-frame Surface
descriptor lookup. One preregistered five-second pair then ran against a fresh
instance of the same 1280x720 Rocky animation workload. The reference collector
and analyzer were unchanged.

| Metric | SwiftSpice | spice-client-glib2 | Swift / GLib | Threshold | Result |
| --- | ---: | ---: | ---: | ---: | --- |
| Published frame rate | 52.0 fps | 49.2 fps | 1.056911 | >= 0.95 | PASS |
| First frame ready | 333.273166 ms | 431.340 ms | 0.772646 | <= 1.10 | PASS |
| Frame interval p95 | 24.313750 ms | 36.079 ms | 0.673903 | <= 1.10 | PASS |
| Observation-window CPU | 0.377439 s | 0.296836 s | 1.271541 | Diagnostic | Recorded |
| CPU per published frame | 1.451688 ms | 1.206650 ms | 1.203073 | <= 1.10 | **FAIL** |
| Maximum RSS | 83,804,160 B | 127,303,680 B | 0.658301 | <= 1.15 | PASS |

SwiftSpice completed 260 frames and the reference client completed 246. Both
passed the activity guard. Frame rate, startup, p95, and RSS passed, but CPU per
published frame remained 20.3% above the reference and exceeded the 1.10 gate.
The overall smoke therefore remained **FAIL**, and the preregistered rule
prevented the ten paired 30-second batch from starting.

The publisher received 14,075 submissions, attempted 265 snapshots, emitted
260 frames, recorded zero stale snapshots and zero pending eviction, and ended
with one surface pending at the observation cutoff. The stale ratio was
therefore **0/265 (0%)**, compared with **48/261 (18.39%)** in the 14:34 sample
below. Five successful snapshot candidates were not emitted; the current
telemetry does not separately count submitted-revision deferrals, so that
difference must not be attributed more precisely from these counters alone.

SwiftSpice reported 14,076 damage operations and 265 Surface snapshots, with
`full_frame_copy_bytes=376,012,800`,
`partial_frame_copy_bytes=14,997,888`, and `gpu_copy_bytes=0`. CPU
materialization, pool exhaustion, GPU error, and pending eviction counters were
all zero.

The CPU-per-frame ratio improved from 1.31379 in the corrected 10:11 smoke to
1.203073 here. This is a cross-run diagnostic, not a confidence interval:
SwiftSpice changed from 1.474 ms to 1.452 ms per frame while the reference also
changed from 1.122 ms to 1.207 ms. A causal or non-inferiority claim still
requires a passing smoke followed by ten complete 30-second pairs.

Local raw output is stored at
`/private/tmp/swiftspice-perf-revision-fix-smoke-20260801T1620`. Remote workload
and round evidence is stored at
`/home/beribeli/swiftspice-remote-closure/perf-ab/logs/20260801T081943Z`.
The base commit was `83efeef1fdbea2013fc3d929f9d157bc8b0861de`; because the
tested fixes were uncommitted, that hash does not identify the complete tested
source. The Release probe SHA-256 was
`911839b9e521f1ab998d9cf6660c02b3372c623e65904f2c65d84218812fa3c8`.

The server logs confirmed two `PERF_LOAD state=animation reset_frame=0`
markers. After capture, the local SSH tunnel and disposable remote QEMU/SPICE
endpoint were stopped, and the temporary ticket was removed.

## Final-tree revisioned IOSurface smoke (14:34)

The final tree was rebuilt as a fresh arm64 release in an independent scratch
directory. The build recompiled `VideoToolboxDecoder.swift`,
`SurfaceStore.swift`, and `SpiceMetalCompositor.swift`. Source hashes matched
before and after acceptance. One corrected five-second pair then ran against the
same 1280x720 Rocky animation workload.

| Metric | SwiftSpice | spice-client-glib2 | Swift / GLib | Threshold | Result |
| --- | ---: | ---: | ---: | ---: | --- |
| Published frame rate | 42.6 fps | 48.0 fps | 0.887500 | >= 0.95 | **FAIL** |
| First frame ready | 344.657416 ms | 323.258 ms | 1.066199 | <= 1.10 | PASS |
| Frame interval p95 | 43.117958 ms | 36.868 ms | 1.169523 | <= 1.10 | **FAIL** |
| Observation-window CPU | 0.188994 s | 0.131035 s | 1.442317 | Diagnostic | Recorded |
| CPU per published frame | 0.887296 ms | 0.545979 ms | 1.625146 | <= 1.10 | **FAIL** |
| Maximum RSS | 83,689,472 B | 127,107,072 B | 0.658417 | <= 1.15 | PASS |

SwiftSpice completed 213 frames and the reference client completed 240. Both
passed the two-frame activity guard. The fps, p95, and CPU-per-frame gates
failed, so the preregistered rules prevented the ten paired 30-second batch from
starting. These results do not establish performance non-inferiority.

SwiftSpice reported 14,442 damage operations, 213 snapshots and emissions,
`gpu_copy_bytes=0`, `full_frame_copy_bytes=390,758,400`, and
`partial_frame_copy_bytes=11,811,072`. CPU materialization, pool exhaustion,
and GPU errors were all zero. The publisher requested 261 snapshots, suppressed
48 stale revisions, and recorded no pending eviction.

Local raw output was stored at
`/private/tmp/swiftspice-final-tree-smoke-ye6C9IP7`. Remote evidence was stored
at
`/home/beribeli/swiftspice-remote-closure/perf-ab/logs/20260801T063457Z`.
The independent build was at
`/private/tmp/swiftspice-final-tree-build-c0g5vi1z`, and the probe SHA-256 was
`9e89deb714d3f8880fa1cc90fc7bcdd795887c8555529e5fce73c8c6e0aa6011`.
The operating system may remove the temporary local directories.

The strict `--require-native-video` gate passed with the same fresh build:

- H.264 published 387 frames at 48.375 fps, completed 233 VideoToolbox frames,
  and performed 14 native Metal compositions.
- H.265 published 402 frames at 50.25 fps, completed 233 VideoToolbox frames,
  and performed 28 native Metal compositions.

Both codecs selected hardware decoding. They reported `gpu_copy_bytes=0`, with
full and partial copies of `3,686,400` and `40,743,680` bytes. VideoToolbox and
general BGRA materialization, CPU/native fallback, GPU errors, generation
disable, and pool exhaustion were all zero. The server confirmed
`selected=h264 streaming=1`, `selected=h265 streaming=1`, and `reset_frame=0`.

Local evidence was stored at
`/private/tmp/swiftspice-final-tree-native-WylhmHzW`. Remote evidence was stored
at
`/home/beribeli/swiftspice-remote-closure/video-live/logs/20260801T063715Z`.
After acceptance, both remote containers, tickets, current-run markers,
5935/5936/5955/5956 listeners, and local 15935/15955 SSH tunnel listeners were
absent. Final server logs and performance-round evidence remain on the remote
host.

## Corrected five-second smoke after CPU hot-path fixes (10:11)

The original reference collector incremented its frame counter only on a 16 ms
tick, while SwiftSpice generated a complete IOSurface for each published frame.
`/usr/bin/time` also mixed connection, GStreamer initialization, and exit CPU
with the observation-period frame count. The corrected method applies the same
work to both clients:

- Each published frame performs an IOSurface lock, a complete BGRA copy, and an
  unlock.
- Both clients use `CLOCK_PROCESS_CPUTIME_ID` for the five-second observation
  window.
- Whole-process CPU from `/usr/bin/time` remains in the raw data but is not a
  display non-inferiority gate.

SwiftSpice also moved GLZ runs to contiguous buffer access, decoded color and
alpha planes in place, wrote directly into `Data` backing storage, used one
contiguous IOSurface copy when strides matched, and replaced temporary byte
arrays with direct unaligned little-endian wire reads.

| Metric | SwiftSpice | spice-client-glib2 | Swift / GLib | Threshold | Result |
| --- | ---: | ---: | ---: | ---: | --- |
| Published frame rate | 51.6 fps | 49.6 fps | 1.04032 | >= 0.95 | PASS |
| First frame ready | 365.9 ms | 371.6 ms | 0.98454 | <= 1.10 | PASS |
| Frame interval p95 | 24.4 ms | 35.6 ms | 0.68522 | <= 1.10 | PASS |
| Observation-window CPU | 0.380 s | 0.278 s | 1.36677 | <= 1.10 | **FAIL** |
| CPU per published frame | 1.474 ms | 1.122 ms | 1.31379 | <= 1.10 | **FAIL** |
| Maximum RSS | 74.5 MiB | 121.3 MiB | 0.61459 | <= 1.15 | PASS |

SwiftSpice completed 258 frames and the reference client completed 248. The
corrected method and code changes reduced the CPU-per-frame gap from 2.16x to
1.31x, but the result still missed the 1.10 threshold. The ten paired 30-second
batch did not start. Valid raw data was stored at
`/private/tmp/swiftspice-iosurface-cleanboot-smoke-20260801T1011`.

Some runs reported the guest control state as `animation` while both clients
received only one static frame. The activity guard rejected those samples. The
valid smoke used a new guest boot epoch, with remote evidence at
`/home/beribeli/swiftspice-remote-closure/perf-ab/logs/20260801T021031Z`.

## Five-second smoke after the first code fixes

After changes to snapshot scheduling, the GLZ dictionary, Surface copy-on-write
and drawing hot paths, and Network.framework lifecycle handling, one final
smoke pair ran in a clean guest boot epoch. This sample decided whether to start
the formal ten-pair test. It cannot replace a formal confidence interval.

| Metric | SwiftSpice | spice-client-glib2 | Swift / GLib | Threshold | Result |
| --- | ---: | ---: | ---: | ---: | --- |
| Published frame rate | 50.4 fps | 47.6 fps | 1.05882 | >= 0.95 | PASS |
| First frame ready | 258.4 ms | 332.4 ms | 0.77747 | <= 1.10 | PASS |
| Frame interval p95 | 23.7 ms | 39.0 ms | 0.60778 | <= 1.10 | PASS |
| Process CPU | 0.87 s | 0.38 s | 2.28947 | <= 1.10 | **FAIL** |
| CPU per published frame | 3.45 ms | 1.60 ms | 2.16228 | <= 1.10 | **FAIL** |
| Maximum RSS | 68.0 MiB | 117.2 MiB | 0.57987 | <= 1.15 | PASS |

SwiftSpice completed 252 frames and the reference client completed 238. No
session failure or Network.framework trap occurred. Display throughput recovered
from the baseline median of 0.467 fps to 50.4 fps, but CPU per frame remained
about 2.16x the reference client. The formal batch did not start, and the
overall non-inferiority result remained **FAIL**. Raw data was stored at
`/private/tmp/swiftspice-fix-smoke-word-copy-20260801T0123`.

## Historical formal comparison

The initial formal comparison failed. It is retained because it records the
baseline that motivated the current publisher, mailbox, Surface, and network
lifecycle work.

### Summary

Ten formal paired runs were attempted against the same 1280x720 QEMU/SPICE
animation workload:

- Nine pairs produced complete 30-second results for both clients.
- In pair 10, spice-client-glib2 completed normally, while SwiftSpice hit a
  fatal Network.framework assertion during connection and exited with
  `Trace/BPT trap`.
- Across the nine complete pairs, the median published frame rate was
  **0.467 fps** for SwiftSpice and **47.0 fps** for the reference client.
- The median paired frame-rate ratio was **0.00993**, with a 95% bootstrap
  confidence interval of **[0.00913, 0.01085]**, below the 0.95 threshold.
- SwiftSpice CPU cost per published frame was **21.11x** the reference client,
  with a 95% confidence interval of **[20.34, 22.40]**.

The display path therefore failed non-inferiority even without pair 10's crash.

### Test environment

#### macOS client

| Item | Value |
| --- | --- |
| System | macOS 26.6 (25G72), arm64 |
| Swift | Apple Swift 6.3.3 |
| SwiftSpice commit | `a81933254d84f9b2e17a4d013a0acaee5d6c8297`, branch `main` |
| SwiftSpice build | SwiftPM Release |
| spice-client-glib2 | 0.42 |
| GLib | 2.88.2 |
| GLib reference collector | `cc -O2 -Wall -Wextra -Werror` |

The working tree contained uncommitted changes during testing, so the commit
identifies only the base revision. Benchmark telemetry changes are in
[`Sources/SpiceProbe/main.swift`](../Sources/SpiceProbe/main.swift).

#### Remote workload

| Item | Value |
| --- | --- |
| SSH alias | `rocky8` |
| Host | Rocky Linux 9.8, x86_64 |
| Virtualization | Rootless Podman 5.8.2 with KVM |
| QEMU | 8.2.2 |
| spice-server | 0.15.1 |
| Guest | Alpine 3.22.5 |
| Resolution | 1280x720 |
| SPICE compression | `auto_glz`, JPEG auto, zlib-glz auto, streaming filter |
| Transport | Remote loopback SPICE through an SSH tunnel |

Valid formal samples span two clean guest boot epochs: `20260801T000942Z` and
`20260801T002056Z`. Their configuration diff contained only `run_id`. Pairs 1
through 7 came from the first epoch, and pairs 8 through 10 came from the
second.

### Method

1. The guest ran a fixed 1280x720 terminal animation targeting 30 fps.
2. Each sample began with a remote round start and animation reset. A separate
   spice-server log slice was saved afterward.
3. Only one client connected at a time. The first client alternated by round.
4. Each sample observed 30 seconds with frame logging disabled and emitted one
   JSON summary.
5. The GLib collector coalesced `display-invalidate` signals on a 16 ms cadence,
   matching the SwiftSpice setting at that revision.
6. The runner rejected samples with fewer than two frames.
7. The analysis bootstrapped the nine complete paired `Swift / GLib` ratios
   10,000 times and reported medians with 95% confidence intervals.
8. A client crash was a hard failure and could not be replaced by a rerun.

Tools:

- [`run_live_pairs.sh`](run_live_pairs.sh)
- [`spice_glib_bench.c`](Reference/spice_glib_bench.c)
- [`analyze.py`](analyze.py)
- [`remote_rocky_hook.sh`](remote_rocky_hook.sh)

### Aggregate results

All ratios are `SwiftSpice / spice-client-glib2`.

| Metric | Swift median | GLib median | Ratio median | 95% CI | Threshold | Result |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| Published frames in 30 seconds | 14 | 1410 | N/A | N/A | N/A | Diagnostic |
| Published frame rate | 0.467 fps | 47.000 fps | 0.00993 | [0.00913, 0.01085] | >= 0.95 | **FAIL** |
| First frame ready | 214.3 ms | 263.4 ms | 0.81062 | [0.75793, 0.87544] | <= 1.10 | PASS |
| Frame interval p95 | 32.5 ms | 38.9 ms | 0.83350 | [0.72648, 0.92627] | <= 1.10 | Diagnostic |
| Process CPU | 0.37 s | 1.72 s | 0.21512 | [0.20219, 0.22289] | <= 1.10 | Diagnostic |
| CPU per published frame | 26.43 ms | 1.25 ms | 21.10940 | [20.33566, 22.39596] | <= 1.10 | **FAIL** |
| Maximum RSS | 37.3 MiB | 117.8 MiB | 0.31674 | [0.31248, 0.31970] | <= 1.15 | PASS* |

`*` GStreamer printed automatic audio-object property warnings during every GLib
startup even with `enable-audio=false`. This can inflate GLib startup CPU and
RSS. The RSS result is therefore a conservative process-level measurement and
does not offset the display-throughput failure.

Lower absolute CPU did not make SwiftSpice more efficient. It published about
one percent as many frames and completed much less display work. CPU per
published frame exposed the 21x single-frame cost.

Frame interval p95 also could not establish smoothness by itself. SwiftSpice
published a small burst during startup and then remained silent for long
periods. The metric did not count the interval from the last frame to the end of
the observation window, so it must be interpreted with overall fps.

### Per-run data

These nine complete pairs entered the bootstrap analysis.

| Run | Swift fps | GLib fps | fps ratio | Swift ready ms | GLib ready ms | Swift CPU s | GLib CPU s | Swift RSS MiB | GLib RSS MiB |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 0.433 | 44.267 | 0.00979 | 240.2 | 296.3 | 0.37 | 1.70 | 37.1 | 119.7 |
| 2 | 0.467 | 48.067 | 0.00971 | 194.3 | 255.4 | 0.34 | 1.53 | 37.4 | 118.0 |
| 3 | 0.467 | 47.000 | 0.00993 | 207.0 | 279.8 | 0.36 | 1.72 | 37.3 | 117.3 |
| 4 | 0.500 | 47.267 | 0.01058 | 193.7 | 255.5 | 0.37 | 1.72 | 37.3 | 117.3 |
| 5 | 0.433 | 48.000 | 0.00903 | 243.4 | 265.0 | 0.37 | 1.83 | 37.6 | 117.3 |
| 6 | 0.500 | 46.100 | 0.01085 | 214.3 | 262.0 | 0.36 | 1.74 | 37.1 | 117.8 |
| 7 | 0.467 | 42.067 | 0.01109 | 205.6 | 263.4 | 0.37 | 1.58 | 37.5 | 120.1 |
| 8 | 0.467 | 46.267 | 0.01009 | 221.5 | 272.2 | 0.37 | 1.66 | 37.2 | 118.1 |
| 9 | 0.433 | 47.467 | 0.00913 | 224.7 | 256.6 | 0.35 | 1.86 | 37.5 | 117.2 |

### Pair 10 crash

Pair 10 ran spice-client-glib2 first. The reference client completed normally:

| Metric | spice-client-glib2 |
| --- | ---: |
| Frames | 1401 |
| fps | 46.700 |
| First frame ready | 265.797 ms |
| Frame interval p95 | 39.013 ms |
| Invalidations | 85,436 |
| CPU | 1.81 s |
| Maximum RSS | 117.3 MiB |

SwiftSpice then exited after about 0.64 seconds without producing JSON. Its
result file was empty.

```text
Network/Connection.swift:5817: Fatal error: Neither nw nor nwGroup is initialized
time: command terminated abnormally
Trace/BPT trap: 5
```

The failed process consumed about 0.36 CPU seconds and reached about 37.3 MiB
RSS. The run remained a hard stability failure and was not replaced.

### Excluded samples

- The first smoke omitted an explicit `spice_channel_connect()` in the GLib
  collector and produced no valid reference result. It was rerun after repair.
- An early formal batch became static after the first round. Both clients saw
  only the initial frame. The raw frame-count guard invalidated the apparent
  pass and rejected the batch.
- The fixture added process-group termination and a parent-process orphan guard,
  then passed 25 consecutive reset cycles.
- Repeated long-running reset cycles could still degrade the Xorg/xterm load.
  The final formal data therefore used two clean boot epochs, and the runner
  rejected every one-frame sample.
- Pair 1 in the second epoch restored the global alternating order and did not
  enter the final statistics. Its following pairs mapped to global pairs 8, 9,
  and the crashing pair 10.

Remote log checks found:

- Epoch `20260801T000942Z` contained 21 round logs and 46 resets. Every round
  recorded `PERF_LOAD state=animation reset_frame=0`.
- Epoch `20260801T002056Z` contained eight round logs and eight resets with the
  same animation-reset evidence.
- Both epochs used identical SPICE, resolution, codec, and compression settings.
  Only `run_id` differed.

### Historical bottleneck evidence

At the recorded revision, each `frameChanged` event built a complete Surface
snapshot before the 16 ms coalescing boundary:

1. `DisplayChannel.run` called `snapshot(surfaceID:)` for each change.
2. `SurfaceStore.snapshot` created an IOSurface frame and placed complete `Data`
   in `FrameSnapshot`.
3. `SpiceSession.received` handed the already-built `SpiceFrame` to the
   coalescer.

Coalescing therefore happened after the expensive full-surface copy. A
1280x720x4 frame is about 3.52 MiB. Frequent partial draws repeatedly triggered
full snapshots and prevented the Display Channel from consuming later SPICE
messages promptly. That behavior matched the short startup burst, long silence,
and high CPU cost per published frame.

The current tree replaces that boundary with
[`DisplayFramePublisher`](../Sources/SpiceChannels/DisplayFramePublisher.swift)
and
[`SpiceSessionEventMailbox`](../Sources/SwiftSpice/SpiceSessionEventMailbox.swift).
This section explains the historical baseline and does not describe the current
implementation.

### Historical conclusion and rerun gate

The headless comparison covered connection, SPICE wire consumption, codec and
draw commands, Surface mutation, snapshot publication, and coalescing. It did
not cover AppKit or GTK window composition, Metal drawables, audio latency, or
input-to-photon latency. The pre-GUI display path had already failed, so GUI
data was not needed to reject the initial non-inferiority claim.

The resulting work order was:

1. Move coalescing and dirty-region scheduling before full Surface snapshots.
2. Fix the `Network.Connection` lifecycle race so failure or cancellation
   cannot reach an uninitialized `nw` or `nwGroup`.
3. Use a persistent animation renderer that does not repeatedly create Xorg and
   xterm windows.
4. After repair, require at least ten complete 30-second pairs with no crashes
   or cross-boot replacement. The fps-ratio 95% confidence-interval lower bound
   must be at least 0.95. CPU-per-frame and first-frame latency upper bounds must
   be at most 1.10.

## Reproduction

```sh
SPICE_PASSWORD='...' \
SWIFTSPICE_BENCH_HOOK_SCRIPT=Benchmarks/remote_rocky_hook.sh \
Benchmarks/run_live_pairs.sh 127.0.0.1 15935 10 30 \
  /private/tmp/swiftspice-live-results

UV_CACHE_DIR=/private/tmp/swiftspice-uv-cache \
uv run --no-project Benchmarks/analyze.py \
  /private/tmp/swiftspice-live-results --json
```

Temporary raw-result directories included:

- `/private/tmp/swiftspice-perf-final-valid9-019fba41`
- `/private/tmp/swiftspice-perf-formal5-019fba41`

The operating system may remove `/private/tmp`. This report preserves the
aggregate values used for the conclusions but does not copy every raw JSON,
`time -lp` output, or remote spice-server log.
