# SwiftSpice performance measurement

## Release microbenchmarks

`spice-bench` is the versioned, deterministic microbenchmark harness. Always
run it as a Release product; a Debug executable exits nonzero instead of
producing an artifact whose metadata incorrectly claims optimized code.

```sh
Benchmarks/run_micro.sh --warmup 3 --iterations 10 > /private/tmp/spice-micro.json
```

The command writes exactly one JSON object to standard output. Schema version
`1` contains `schema_version`, `artifact_kind`, reproducibility `metadata`, and
the stable ordered `cases` catalog. Every case records warm-up and measured
iteration counts, nonzero checksum evidence against dead-code elimination,
raw duration samples in measured order, derived duration statistics in
nanoseconds, and its owning algorithm's exact counters. Raw samples are retained
so later analysis can compute bootstrap confidence intervals instead of trying
to reconstruct them from lossy summary statistics.
The current stable case IDs are:

- `wire.contiguous`
- `wire.fragmented`
- `region.normalization`
- `copy_bits`
- `lz`
- `glz`
- `iosurface.transition`
- `advanced_video.sample`

Acceptance counters are validated before JSON is emitted. They include zero
contiguous wire body copies, at most one body-sized fragmented copy, one
transaction and zero temporary bytes for COPY_BITS, a single bulk/zero-row
tightly packed full cross-Surface IOSurface copy, zero CPU materialization for the following
1x1 canonical mutation, and the codec/parser allocation counters. The
IOSurface case explicitly fails on unsupported hardware rather than silently
measuring the Data fallback. Metadata includes commit, Swift toolchain,
hardware model when available plus non-identifying architecture/resource/OS
fallback details, thermal state, workload version, mode, and UTC date.
Advanced-video counters distinguish bytes written directly into the single
AVCC allocation from additional sample materialization; the latter must remain
zero.

Microbenchmark JSON is not a live-client performance result. `spice-bench
--live` checks the external endpoint/credential prerequisites but deliberately
exits nonzero and emits no artifact; formal live results must come from the
paired runner below.

## Live SPICE performance comparison

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
