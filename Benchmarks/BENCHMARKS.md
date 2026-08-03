# Live SPICE performance comparison

This directory contains a low-noise, headless comparison between SwiftSpice and
the installed `spice-client-glib-2.0` reference client. It is an engineering
performance gate, not a claim that the two event models are ABI-equivalent.

Both clients connect separately to the same resettable QEMU/SPICE workload. The
reference collector coalesces `display-invalidate` signals on a 16 ms cadence,
matching SwiftSpice's default frame-coalescing interval. Each process prints one
JSON object after the observation interval; frame-by-frame logging is disabled.

## Latest retained result

The 2026-08-02 Rocky run exercised CPU and Metal at 1280x720 and 3840x2160.
Every continuous eight-pair diagnostic prefix failed the CPU-per-frame gate;
the 4K Metal prefix also failed RSS. The intended formal ten-pair verdict is
**invalid**, not a performance pass or failure, because the old guest reset
fixture stopped producing activity in the late pairs. Metal lifecycle evidence
remained clean in all 20 measured Metal processes. See
[RESULTS_ROCKY8_2026-08-02.md](RESULTS_ROCKY8_2026-08-02.md) for the complete
ratios, evidence boundaries, fixture repair, and rerun criteria.

Build the two collectors on macOS:

```sh
swift build -c release --product spice-probe
cc -O2 -Wall -Wextra -Werror \
  Benchmarks/Reference/spice_glib_bench.c \
  $(pkg-config --cflags --libs spice-client-glib-2.0) \
  -framework CoreFoundation -framework IOSurface \
  -o /private/tmp/spice-glib-bench
```

Open an SSH tunnel to a SPICE listener bound to loopback on the remote host,
then run the clients one at a time. The ticket is read from `SPICE_PASSWORD` and
must not be placed on the command line or committed to an output file.

```sh
SPICE_PASSWORD='...' .build/release/spice-probe \
  127.0.0.1 15930 --observe-seconds 30 --benchmark-json --renderer metal

SPICE_PASSWORD='...' /private/tmp/spice-glib-bench 127.0.0.1 15930 30
```

Reset the guest workload between clients and alternate their order. For the
current selected-Swift-renderer versus spice-client-glib2 runner, use at least
ten paired runs for a non-inferiority decision. Compare paired bootstrap
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
existing output directory. Every sample must cover at least 80% of the
observation span and 8 of 10 time buckets, with its last frame no more than one
second before the window ends. The runner records the client exit code and
guest boot epoch in `run-NN-CLIENT.meta.json`; nonzero exit is invalid even if
the client printed complete JSON. If the guest
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

`SWIFTSPICE_BENCH_RENDERER` selects one complete rendering configuration:

| Value | Ordinary 2D engine | Surface backing | Intended use |
| --- | --- | --- | --- |
| `automatic` | CPU | Automatic; revisioned IOSurface when supported | Production default |
| `cpu` | CPU | Data | Historical reference-compatible benchmark |
| `cpu-iosurface` | CPU | Required revisioned IOSurface | Matched-backing Metal candidate; current runner still pairs it with GLib |
| `metal` | Experimental Metal 2D | Required revisioned IOSurface | Explicit GPU experiment; runner default |

Both the runner and analyzer reject a sample whose observed backing or Metal
2D state does not match the requested configuration. A required revisioned run
fails rather than silently falling back to Data. The JSON report includes 2D
command-buffer and command
counts, shared-buffer upload bytes, scratch/copy blit bytes, completed GPU time,
CPU materializations, and GPU errors. Frames count only after Metal completion;
a valid Metal sample must execute at least one 2D command buffer and command,
while keeping CPU materialization, GPU errors, pool exhaustion, the dedicated
Metal-to-CPU fallback count, and all four Metal-supported CPU opcode counts at
zero. `automatic` samples require observed CPU opcode activity and zero GPU or
pool failures. MJPEG `cpu-iosurface` samples additionally require zero CPU
materializations. Both the runner and the analyzer reject samples that fail
these evidence gates. The report separates revision GPU clones, Metal-batch
CPU/GPU seed copies, snapshot catch-up copies, 2D opcodes, the dedicated
`metal_2d_cpu_fallback_operations` count, and upload-buffer
allocations/reuses. CPU fallback opcodes include aggregate nanosecond timings.

The current paired analyzer compares the selected Swift configuration with
spice-client-glib2; it cannot directly pair two Swift renderer configurations.
A claim that Metal 2D improves SwiftSpice requires a dedicated direct-pair
runner and analyzer comparing `cpu-iosurface` with `metal` under the same guest
epoch, reset sequence, resolution, and client-order schedule. Two separate
Swift-versus-GLib result directories do not satisfy that paired contract. The
historical `cpu` versus `metal` absolute medians changed both the draw engine
and backing policy and therefore do not isolate the effect of Metal 2D.

The runner requires a guest boot epoch. Set `SWIFTSPICE_BENCH_BOOT_EPOCH` when
the complete batch is guaranteed to remain in one epoch, or provide an
executable `SWIFTSPICE_BENCH_BOOT_EPOCH_SCRIPT`. The script receives
`RUN_NUMBER CLIENT` after reset and the before-hook, and must print one stable,
non-empty line such as the guest `/proc/sys/kernel/random/boot_id`. Both clients
inside a pair must report the same value; epochs may change between pairs.

By default, the runner stops at the first process or evidence failure. Set
`SWIFTSPICE_BENCH_CONTINUE_ON_FAILURE=1` only when the test contract requires
collecting the entire batch despite failures. Such failures are recorded in
`integrity-failures.tsv`; the final analyzer still rejects the batch, so this
mode cannot turn incomplete evidence into a passing result. The analyzer also
rejects mixed renderer or codec configurations and requires every metric to be
present and usable in every requested pair.

```sh
SPICE_PASSWORD='...' \
SWIFTSPICE_BENCH_RESET_SCRIPT=/private/tmp/reset-spice-workload \
SWIFTSPICE_BENCH_BOOT_EPOCH_SCRIPT=/private/tmp/read-guest-boot-id \
Benchmarks/run_live_pairs.sh 127.0.0.1 15930 10 30 \
  /private/tmp/swiftspice-live-results

uv run Benchmarks/analyze.py /private/tmp/swiftspice-live-results
```

The analyzer exits nonzero when any confidence-interval gate fails. A formal
selected-Swift-renderer versus GLib decision uses exactly `10` pairs of `30`
seconds and should pass `--expected-pairs 10`; shorter runs are smoke tests
only.

This headless gate covers connection, wire processing, codec execution, Surface
mutation, snapshot publication, and coalescing. It does not cover AppKit/GTK
window composition, actual drawable presentation, audio-device latency, or
input-to-photon latency; those remain separate real-window gates.
