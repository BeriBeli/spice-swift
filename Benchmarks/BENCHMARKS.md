# Live SPICE performance comparison

This directory contains a low-noise, headless comparison between SwiftSpice and
the installed `spice-client-glib-2.0` reference client. It is an engineering
performance gate, not a claim that the two event models are ABI-equivalent.

Both clients connect separately to the same resettable QEMU/SPICE workload. The
reference collector coalesces `display-invalidate` signals on a 16 ms cadence,
matching SwiftSpice's default frame-coalescing interval. Each process prints one
JSON object after the observation interval; frame-by-frame logging is disabled.

Build the two collectors on macOS:

```sh
swift build -c release --product spice-probe
cc -O2 -Wall -Wextra -Werror \
  Benchmarks/Reference/spice_glib_bench.c \
  $(pkg-config --cflags --libs spice-client-glib-2.0) \
  -o /private/tmp/spice-glib-bench
```

Open an SSH tunnel to a SPICE listener bound to loopback on the remote host,
then run the clients one at a time. The ticket is read from `SPICE_PASSWORD` and
must not be placed on the command line or committed to an output file.

```sh
SPICE_PASSWORD='...' .build/release/spice-probe \
  127.0.0.1 15930 --observe-seconds 30 --benchmark-json

SPICE_PASSWORD='...' /private/tmp/spice-glib-bench 127.0.0.1 15930 30
```

Reset the guest workload between clients and alternate their order. Use at
least ten paired runs for a non-inferiority decision. Compare paired bootstrap
confidence intervals rather than a single run. Frame counts are comparable
only for the fixed 16 ms publication cadence; the raw GLib `invalidations`
counter is diagnostic and has no direct SwiftSpice equivalent.
CPU time is reported both per process and per published frame. The normalized
metric prevents a client that publishes far fewer frames from appearing more
efficient merely because it performs less display work.
Use `ready_frame_ms` for the cross-client startup comparison: it spans process
connection initiation through the first 16 ms publication tick. `connect_ms`
and `first_frame_ms` expose client-specific phase boundaries and are diagnostic,
because SwiftSpice session readiness and GLib primary-surface creation are not
the same API event.

`run_live_pairs.sh` automates optimized builds, alternating client order, JSON
validation, and macOS `time -lp` resource capture. It refuses to overwrite an
existing output directory. It also rejects samples with fewer than two frames
so that a dead or static workload cannot produce a false non-inferiority pass
without masking a genuinely slow client. If the guest
exposes a reset command, provide a
small executable wrapper with `SWIFTSPICE_BENCH_RESET_SCRIPT`; the runner calls
it as `RESET_SCRIPT RUN_NUMBER CLIENT` before every measurement.
For server-side log slicing, `SWIFTSPICE_BENCH_HOOK_SCRIPT` receives
`before|after RUN_NUMBER CLIENT`; its `after` phase also runs when a measured
client exits unsuccessfully.

Set `SWIFTSPICE_BENCH_VIDEO_CODEC=h264` or `h265` for the real native-video
gate. The Swift sample then also requires decoded VT frames, at least one native
Metal composition, zero BGRA materializations/fallback frames, zero GPU errors,
and zero permanent stream-generation disables. Hardware decoding itself is
reported as hardware/software/query counters but is not required: VideoToolbox
may legitimately select its software decoder.

```sh
SPICE_PASSWORD='...' \
SWIFTSPICE_BENCH_RESET_SCRIPT=/private/tmp/reset-spice-workload \
Benchmarks/run_live_pairs.sh 127.0.0.1 15930 10 30 \
  /private/tmp/swiftspice-live-results

uv run Benchmarks/analyze.py /private/tmp/swiftspice-live-results
```

The analyzer exits nonzero when any confidence-interval gate fails. A formal
decision uses exactly `10` pairs of `30` seconds and should pass
`--expected-pairs 10`; shorter runs are smoke tests only.

This headless gate covers connection, wire processing, codec execution, Surface
mutation, snapshot publication, and coalescing. It does not cover AppKit/GTK
window composition, actual drawable presentation, audio-device latency, or
input-to-photon latency; those remain separate real-window gates.

For deterministic local profiling of the CPU display chain without a Rocky/QEMU
fixture, see [`CPU_HOT_PATH_LOCAL.md`](CPU_HOT_PATH_LOCAL.md). That benchmark is
environment-gated and separately exercises Data-only and revisioned-IOSurface
publication through real mini-header channel processing. Its paced mode checks
16 ms publication behavior; its complementary saturation mode removes input
sleeps, forbids publication during ingest, and performs one final drain for
lower-noise CPU-throughput A/B tests. A separate opt-in diagnostic mode reports
sampled wire, decode, message handling, SurfaceStore actor round-trip,
publisher submit/emit, renderer, snapshot, and damage-plan phases without
adding clock reads to the default disabled path.
The exact 2026-08-04 same-harness paired evidence, complete attempt ledger,
bootstrap statistics, and scoped no-speedup conclusion are in
[`CPU_HOT_PATH_RESULTS_2026-08-04.md`](CPU_HOT_PATH_RESULTS_2026-08-04.md).
The complementary 2026-08-04 CPU-saturation commit A/B for the isolated
`ChannelSerialBarrier.record()` empty-waiter fast path is in
[`CPU_SATURATION_RESULTS_2026-08-04.md`](CPU_SATURATION_RESULTS_2026-08-04.md).
Two independent batches find no reliable 720p or RSS change. The 4K rerun
detects a small CPU decrease that the original batch did not, so the report
treats it as a signal rather than a replicated production-speedup claim.
