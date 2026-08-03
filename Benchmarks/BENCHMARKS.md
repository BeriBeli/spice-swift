# Live SPICE performance comparison

This directory contains a low-noise, headless comparison between SwiftSpice and
the installed `spice-client-glib-2.0` reference client. It is an engineering
performance gate, not a claim that the two event models are ABI-equivalent.

Both clients connect separately to the same resettable QEMU/SPICE workload. The
reference collector coalesces `display-invalidate` signals on a 16 ms cadence,
matching SwiftSpice's default frame-coalescing interval. Each process prints one
JSON object after the observation interval; frame-by-frame logging is disabled.

## Latest retained results

The 2026-08-03 Rocky rerun exercised CPU and Metal at 1280x720 and 3840x2160
from PR #4 head `d68a8ec`. All requested ten-by-30-second batches were collected,
including samples after evidence failures, but the formal verdict remains
**invalid**: the guest workload again stopped producing sustained activity in
late samples. Activity-valid diagnostics failed CPU per published frame in all
four configurations; 4K Metal also failed RSS. Metal renderer evidence remained
pure and lifecycle-stable in all 20 Metal processes. The counters identify one
full-surface canonical clone per command buffer plus large snapshot catch-up
copies as the primary Metal data-movement costs. See
[RESULTS_ROCKY8_2026-08-03.md](RESULTS_ROCKY8_2026-08-03.md) for the complete
ratios, absolute medians, rejected samples, raw evidence paths, and next gate.
The sanitized [evidence archive](Results/2026-08-03/) retains all formal raw
samples, the activity-valid diagnostic selections, the 4K preflight, analyzer
outputs, exact tested tools, and checksums so reviewers do not depend on
ephemeral `/private/tmp` paths.

A direct matched-backing follow-up at PR #4 head `bb3b176` then paired
`cpu-iosurface` with `metal` on the same guest boot at both resolutions. All
20 samples were collected at each resolution, but the formal 720p batch had
nine incomplete-activity samples and the 4K batch had eight. The contiguous
activity-valid prefixes (pairs 1-5 at 720p and 1-6 at 4K) are diagnostic only
and both fail the performance analyzer: Metal/CPU-IOSurface CPU per frame was
1.730965 at 720p and 1.754194 at 4K; 4K RSS was 1.340859. Guest heartbeats
continued throughout every failed sample, which places the stall downstream
of the generator without identifying xterm, Xorg, spice-server, transport, or
the client as the exact cause. See
[RESULTS_DIRECT_ROCKY8_2026-08-03.md](RESULTS_DIRECT_ROCKY8_2026-08-03.md) and
the direct evidence archive in [Results/2026-08-03](Results/2026-08-03/).

The earlier [2026-08-02 result](RESULTS_ROCKY8_2026-08-02.md) remains available
as historical evidence; it must not be combined with the new batches to create
a synthetic formal result.

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
| `cpu-iosurface` | CPU | Required revisioned IOSurface | Matched-backing reference for the direct Metal A/B |
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
`metal_2d_gpu_time_ns` covers the Metal 2D draw command buffer only. The
revisioned-pool seed blit uses a separate command queue and is not included, so
this counter must not be presented as total GPU time or total GPU utilization.
Scaled copy remains a CPU opcode outside the four currently supported Metal 2D
opcodes and must be reported separately when interpreting a workload.

`run_renderer_pairs.sh` and `analyze_renderer_pairs.py` provide the direct
matched-backing comparison required for a Metal-benefit claim. They alternate
`cpu-iosurface -> metal` in odd pairs and `metal -> cpu-iosurface` in even
pairs, with a deterministic reset before each sample. The analyzer computes
pairwise `metal / cpu-iosurface` ratios and requires one boot epoch, codec,
resolution, observation duration, reset source, and frame byte footprint for
the entire batch. It also rejects incomplete/non-contiguous pairs, order
errors, process/hook failures, incomplete activity, renderer/backing mismatch,
fallback evidence, Metal scaled-copy CPU work, cpu-iosurface materialization,
and unusable metrics. The boot-epoch script runs before and after every sample;
both readings must match, and the same epoch must cover the whole batch. The
resolution must be supplied as
`SWIFTSPICE_BENCH_RESOLUTION=WIDTHxHEIGHT`; each sample must report exactly
`frames * width * height * 4` bytes.

Run the direct pair on the macOS host because building and exercising the
Metal/IOSurface renderer is not a sandbox-safe operation. The Rocky wrappers
assume the `rocky8` SSH alias and the deployed remote fixture:

```sh
SPICE_PASSWORD='...' \
SWIFTSPICE_BENCH_REMOTE_ROCKY_DIRECTORY=/home/beribeli/swiftspice-remote-closure/direct-bb3b176-20260803-v1-4k/remote \
SWIFTSPICE_BENCH_ROUND_EVIDENCE_DIRECTORY=/private/tmp/swiftspice-renderer-pairs-4k/remote-rounds \
SWIFTSPICE_BENCH_HOOK_SCRIPT=Benchmarks/remote_rocky_hook.sh \
SWIFTSPICE_BENCH_BOOT_EPOCH_SCRIPT=Benchmarks/remote_rocky_boot_epoch.sh \
SWIFTSPICE_BENCH_RESOLUTION=3840x2160 \
Benchmarks/run_renderer_pairs.sh 127.0.0.1 15935 10 30 \
  /private/tmp/swiftspice-renderer-pairs-4k

uv run Benchmarks/analyze_renderer_pairs.py \
  /private/tmp/swiftspice-renderer-pairs-4k --expected-pairs 10

uv run Benchmarks/analyze_guest_telemetry.py \
  /private/tmp/swiftspice-renderer-pairs-4k \
  /private/tmp/swiftspice-renderer-pairs-4k/remote-rounds \
  --expected-pairs 10 --observe-seconds 30
```

The guest analyzer also requires the runner's alternating sample order, one
batch-wide boot epoch and generator PID, exactly one generation advance per
reset, non-overlapping monotonic-uptime windows, and no heartbeat gap above five
seconds. It is an independent fixture gate; it does not replace renderer/client
activity validation.

`SWIFTSPICE_BENCH_REMOTE_ROCKY_DIRECTORY` routes both Rocky wrappers to an
isolated fixture whose path ends in `/remote`.
`SWIFTSPICE_BENCH_ROUND_EVIDENCE_DIRECTORY` downloads the exact server log,
guest telemetry, configuration, and version files named by each completed
round. The resolution variable declares and validates the expected frame-byte
footprint; it does not resize or reconfigure the guest. A real 4K run therefore
requires a fixture whose guest X server and QEMU configuration already use
3840x2160.

The direct runner was exercised at `bb3b176`, but both complete ten-pair
batches were invalid because activity failed late in the persistent fixture;
their valid prefixes also failed the performance analyzer. This provides no
formal Metal-benefit result. Two separate Swift-versus-GLib result directories
still do not satisfy the paired contract, and historical `cpu` versus `metal`
absolute medians changed both the draw engine and backing policy.

The selected-renderer-versus-GLib runner accepts `SWIFTSPICE_BENCH_BOOT_EPOCH`
when the complete batch is independently guaranteed to remain in one epoch, or
an executable `SWIFTSPICE_BENCH_BOOT_EPOCH_SCRIPT`. The direct renderer runner
requires the executable script so it can verify the guest before and after each
sample. The script receives `RUN_NUMBER CLIENT_OR_RENDERER` after reset and the
before-hook, and must print one stable, non-empty line such as the guest
`/proc/sys/kernel/random/boot_id`. The selected runner requires both clients
inside a pair to match; the direct runner additionally requires one epoch for
the full batch.

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

Use `archive_results.sh` to preserve a sanitized selected-renderer-versus-GLib
result set together with the exact tested analyzer/runner and their Git blob
IDs. It refuses to overwrite an archive, omits the generated GLib binary,
scans JSON for credential fields, records each analyzer exit code, and writes
per-file SHA-256 checksums:

```sh
Benchmarks/archive_results.sh /private/tmp/evidence.tar.gz TESTED_GIT_REF \
  /private/tmp/raw-results /private/tmp/diagnostic-results
```

Use `archive_renderer_results.sh` for direct renderer evidence. It archives
each direct result set, the exact runner and analyzers, guest telemetry and
round configuration/version files, analyzer outputs and exit codes, a
manifest, and per-file checksums while rejecting credentials and unsafe input
layouts:

```sh
Benchmarks/archive_renderer_results.sh /private/tmp/direct-evidence.tar.gz \
  TESTED_GIT_REF /private/tmp/direct-raw /private/tmp/direct-valid-prefix
```

This headless gate covers connection, wire processing, codec execution, Surface
mutation, snapshot publication, and coalescing. It does not cover AppKit/GTK
window composition, actual drawable presentation, audio-device latency, or
input-to-photon latency; those remain separate real-window gates.
