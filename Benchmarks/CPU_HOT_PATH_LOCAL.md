# Local CPU display hot-path benchmark

The exact 2026-08-04 same-harness paired run and its raw artifacts are
documented in
[`CPU_HOT_PATH_RESULTS_2026-08-04.md`](CPU_HOT_PATH_RESULTS_2026-08-04.md).
Revalidate its formal JSONL and attempt ledger with:

```sh
uv run --no-project Benchmarks/analyze_cpu_hotpath.py \
  Benchmarks/Results/CPUHotPath_2026-08-04 --check
```

`CPUHotPathBenchmarkTests` is an opt-in, host-only Swift Testing benchmark for
the production CPU display path. It provides paced publication and unpaced
CPU-saturation modes. It is inert unless
`SWIFTSPICE_CPU_HOTPATH_BENCHMARK=1` is present, so a normal `swift test` does
not allocate a large surface, create an IOSurface, or wait for benchmark
cadence.

The deterministic input is one display surface followed by 1,500 input frames.
Every input frame contains 57 unscaled 32 x 25 xRGB RAW `DRAW_COPY` commands,
each with an exact 3,200-byte pixel payload. The transport replays real SPICE
mini-header wire bytes at 16 ms frame boundaries. The measured path is:

```text
paced SpiceTransport
  -> ChannelConnection
  -> MessageFramer (mini header)
  -> SpiceServerMessageDecoder
  -> DisplayChannel
  -> SurfaceStore
  -> DisplayFramePublisher (16 ms)
  -> benchmark frame sink
```

The sink retains the latest published `FrameSnapshot`. The next revision is
therefore created while the previous consumer lease is still alive, matching
the two-frame revision ring exercised by the production mailbox/presenter more
closely than an immediately released snapshot.

After the paced input is exhausted, the transport reports that it is ready to
drain and waits on a separate finish gate instead of returning EOF. The test
waits for the sink to observe the exact final surface revision, then crosses
the publisher metrics actor until `emitted_frames` has caught up with the sink.
Only then does it open the finish gate, accept the expected EOF, and await the
channel task. This gives emit completion and counter publication a strict
happens-before relationship; fixed sleeps and yields are not accepted as proof
that final publication completed. The post-input publication/drain gates have
explicit failure timeouts.

Fixture construction happens before timing starts. A single 57-command wire
template is reused rather than allocating the roughly 280 MiB required to hold
all 85,500 formal commands at once. Destination rectangles and pixels are
fixed, not random.

## Input modes

- `paced` is the default. It replays one 57-command input frame every 16 ms and
  leaves the 16 ms publisher active. This mode measures product-like
  publication cadence, coalescing, snapshot behavior, and end-to-end process
  cost, but its low CPU duty cycle is noisy for small throughput changes.
- `saturation` (alias `unpaced`) replays the same commands without sleeping,
  sets the automatic publisher deadline to ten minutes, proves that no
  snapshot or IOSurface allocation occurred during ingest, then performs
  exactly one explicit final publication. It is intended for commit-to-commit
  CPU hot-path comparisons, not latency or published-FPS claims.

Both modes use a transport start gate after surface creation. Schema-v2 output
adds `input_mode`, `ingest_*`, and `end_to_end_*` fields. Exact ingest
timestamps are captured immediately before the first bitmap wire byte and when
the channel requests input after processing the final command. Saturation
end-to-end fields add the one final drain to ingest; pre-drain auditing and EOF
cleanup are excluded. The legacy process fields retain their earlier
run-task-to-EOF boundary for continuity, but populations from different input
modes must never be mixed.

## Backends

- `data-only` uses `SurfaceBackingPolicy.dataOnly` and a deliberately disabled
  legacy `IOSurfaceFramePool`. This is the historical Data-only reference, not
  the production GUI publication path. Its `pool_exhaustions` count therefore
  follows snapshot attempts by construction; this does not mean an unexpected
  allocation failure occurred.
- `cpu-iosurface` uses an explicitly capability-gated
  `RevisionedIOSurfacePool`. This corresponds to CPU 2D mutation plus
  revisioned IOSurface publication. It requires a supported Apple Silicon host
  and must not silently fall back to Data.

Both backends disable the legacy one-shot IOSurface pool so their path identity
is unambiguous.

## Host-only smoke

The repository `AGENTS.md` requires IOSurface and Metal-related Swift tests to
run outside the sandbox. Start with two input frames for each backend:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/swiftspice-cpu-hotpath-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/swiftspice-cpu-hotpath-swiftpm \
SWIFTSPICE_CPU_HOTPATH_BENCHMARK=1 \
SWIFTSPICE_CPU_HOTPATH_BACKEND=data-only \
SWIFTSPICE_CPU_HOTPATH_RESOLUTION=720p \
SWIFTSPICE_CPU_HOTPATH_FRAMES=2 \
swift test -c release --disable-sandbox -Xswiftc -warnings-as-errors \
  --filter CPUHotPathBenchmarkTests

CLANG_MODULE_CACHE_PATH=/private/tmp/swiftspice-cpu-hotpath-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/swiftspice-cpu-hotpath-swiftpm \
SWIFTSPICE_CPU_HOTPATH_BENCHMARK=1 \
SWIFTSPICE_CPU_HOTPATH_BACKEND=cpu-iosurface \
SWIFTSPICE_CPU_HOTPATH_RESOLUTION=720p \
SWIFTSPICE_CPU_HOTPATH_FRAMES=2 \
swift test -c release --disable-sandbox -Xswiftc -warnings-as-errors \
  --filter CPUHotPathBenchmarkTests
```

The timed run is followed by an untimed revision and pixel check. This keeps
the correctness readback out of CPU, RSS, snapshot, and materialization
measurements.

To smoke the CPU-saturation path, add
`SWIFTSPICE_CPU_HOTPATH_INPUT_MODE=saturation`. A valid saturation sample must
report one snapshot and one emitted frame. CPU-IOSurface must allocate one
surface-sized revision, upload one full frame, and retain one lease; Data-only
must perform one full Data snapshot and report the deliberately disabled legacy
pool once. Both paths reject pre-drain publication, GPU/video activity,
materialization, revisioned fallback, and stale or pending output.

## Single-commit sampling matrix

The default is 1,500 input frames, approximately 24 seconds at the fixed input
cadence. Run one backend and resolution per process so each invocation emits
exactly one benchmark JSON object and process RSS is not inherited from an
earlier case. Phase timing is disabled in this matrix. Prebuild the Release
test bundle once, then run each sample in a fresh process with `--skip-build`:

```sh
set -euo pipefail

CLANG_MODULE_CACHE_PATH=/private/tmp/swiftspice-cpu-hotpath-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/swiftspice-cpu-hotpath-swiftpm \
swift test -c release --disable-sandbox -Xswiftc -warnings-as-errors \
  --filter CPUHotPathBenchmarkTests

for resolution in 720p 4k; do
  for backend in data-only cpu-iosurface; do
    CLANG_MODULE_CACHE_PATH=/private/tmp/swiftspice-cpu-hotpath-clang \
    SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/swiftspice-cpu-hotpath-swiftpm \
    SWIFTSPICE_CPU_HOTPATH_BENCHMARK=1 \
    SWIFTSPICE_CPU_HOTPATH_DIAGNOSTICS=0 \
    SWIFTSPICE_CPU_HOTPATH_BACKEND="$backend" \
    SWIFTSPICE_CPU_HOTPATH_RESOLUTION="$resolution" \
    swift test -c release --skip-build --disable-sandbox \
      --filter CPUHotPathBenchmarkTests
  done
done
```

`SWIFTSPICE_CPU_HOTPATH_FRAMES` accepts `1...10000`; omit it for the formal
1,500-frame workload. Accepted resolution aliases are `720p`/`1280x720` and
`4k`/`3840x2160`. If backend or resolution is omitted, the defaults are
`cpu-iosurface` and `720p`.

This loop characterizes two backends from one checkout. It is not a
commit-to-commit A/B: `data-only` is a historical diagnostic reference, not
the production GUI publication path. A PR-level A/B compares only
`cpu-iosurface`, alternates baseline-first and optimized-first fresh processes,
retains every attempt, and requires both builds to use byte-identical benchmark
source. The checked-in 2026-08-04 evidence used a baseline-compatible harness
for that purpose. The enhanced HEAD harness was then run separately with
diagnostics enabled; those populations are not mixed.

## Formal CPU-saturation commit A/B

The saturation protocol fixes the workload at 6,000 input frames (342,000
commands), 10 pairs per resolution, alternating baseline-first and
optimized-first order, and four discarded balanced warmups. The 6,000-frame
count was predeclared before the formal run: a two-frame host smoke measured
about 0.33 ms of ingest process CPU for 114 commands, which projects to about
one CPU second per formal sample. The analyzer will reject any other frame or
attempt count.

Run the paired protocol outside the Codex sandbox from a clean repository. The
runner creates detached worktrees and independent Release build/module caches,
requires a byte-identical benchmark harness at both commits, launches a fresh
`swift test` process for every attempt, and stops without replacement if any
attempt fails:

```sh
uv run --no-project Benchmarks/run_cpu_saturation_ab.py \
  --baseline <exact-baseline-commit> \
  --optimized <exact-optimized-commit> \
  --output Benchmarks/Results/CPUSaturation_<YYYY-MM-DD> \
  --host-execution-confirmed
```

Recompute the paired medians and deterministic 95% bootstrap intervals with:

```sh
uv run --no-project Benchmarks/analyze_cpu_saturation.py \
  Benchmarks/Results/CPUSaturation_<YYYY-MM-DD> --check
```

The primary metric is `ingest_cpu_nanoseconds_per_command`. End-to-end CPU,
current RSS, and peak RSS are secondary characterization metrics; saturation
published FPS and p95 interval are not performance claims. The analyzer accepts
only schema-v2 CPU-IOSurface saturation samples with exactly one final
snapshot, zero diagnostic clocks, zero fallback/GPU/video activity, complete
revision and copy-byte accounting, exact AB/BA order, and an unbroken attempt
ledger. It also re-extracts the sample from every retained process log and
validates the canonical 54-file `SHA256SUMS` manifest, including the exact
runner and analyzer copies used for the run.

Runner and analyzer bytes are recorded and locked by SHA-256. Revalidate old
evidence with the scripts from its source commit; changing either tool creates
a new evidence protocol implementation rather than silently reinterpreting an
old archive.

## Diagnostic matrix

Phase timing has a separate explicit gate and must not be enabled for an
uninstrumented performance population. Add
`SWIFTSPICE_CPU_HOTPATH_DIAGNOSTICS=1` when the goal is attribution rather than
an A/B decision:

```sh
set -euo pipefail

for resolution in 720p 4k; do
  for backend in data-only cpu-iosurface; do
    CLANG_MODULE_CACHE_PATH=/private/tmp/swiftspice-cpu-hotpath-clang \
    SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/swiftspice-cpu-hotpath-swiftpm \
    SWIFTSPICE_CPU_HOTPATH_BENCHMARK=1 \
    SWIFTSPICE_CPU_HOTPATH_DIAGNOSTICS=1 \
    SWIFTSPICE_CPU_HOTPATH_BACKEND="$backend" \
    SWIFTSPICE_CPU_HOTPATH_RESOLUTION="$resolution" \
    swift test -c release --disable-sandbox -Xswiftc -warnings-as-errors \
      --filter CPUHotPathBenchmarkTests
  done
done
```

Diagnostic and uninstrumented process CPU numbers are different populations;
do not mix them in the same paired comparison. For a quick instrumentation
smoke, additionally set `SWIFTSPICE_CPU_HOTPATH_FRAMES=2`.

### Phase timing boundaries

Diagnostics are opt-in all the way down the pipeline. With diagnostics
disabled, the phase recorders do not read their monotonic clock. With
`SWIFTSPICE_CPU_HOTPATH_DIAGNOSTICS=1`, the wire framer next/append calls,
display message handling, display decode, bitmap SurfaceStore round-trip, and
publisher submit round-trip sample one invocation out of every 64. Frame emit
and the existing snapshot phases sample every invocation. A short smoke may
have fewer than 64 framer appends and therefore legitimately report zero append
samples while still reporting a period of 64.

The phase boundaries are:

- wire framer next and append cover only `MessageFramer.nextMessage()` and
  `MessageFramer.append()` inside `ChannelConnection`; transport read wait is
  outside both spans;
- display message handling starts only after `ChannelConnection.receive()` has
  returned and covers decode, switch dispatch, validation, cache work,
  SurfaceStore calls, and acknowledgement;
- display message decode covers only `SpiceServerMessageDecoder.decode`;
- bitmap SurfaceStore round-trip begins immediately before the actor call and
  ends after it returns, so it includes executor queueing plus SurfaceStore
  execution and must not be described as pure actor wait;
- publisher submit round-trip likewise includes executor queueing and submit
  execution;
- frame emit covers the asynchronous frame-sink call through its return.

Message handling contains decode and, for bitmap commands, the SurfaceStore
round-trip. These are nested spans and must not be added together. Enabling all
timers also means the outer handling sample includes the small cost of clock
reads made by nested sampled spans.

Each timed phase emits `sample_period`, `samples`, and
`sampled_nanoseconds` fields under these JSON prefixes:
`wire_framer_next`, `wire_framer_append`, `display_message_handling`,
`display_message_decode`, `bitmap_surface_store_round_trip`,
`publisher_submit_round_trip`, `frame_emit`, `bitmap_validation`,
`bitmap_mutation`, `bitmap_damage_journal`, `snapshot_checkout`,
`snapshot_damage_plan`, `snapshot_cpu_copy`, and `snapshot_finish`.

## JSON output and interpretation

The test prints one compact JSON object with lexicographically sorted,
snake-case keys. Swift Testing prints its own progress around that line; the
benchmark record is the line beginning with `{`.

The schema contains:

- workload identity: backend, resolution, frames, commands, bitmap geometry,
  and the 16 ms publisher interval;
- process measurements: wall time, process CPU time, CPU ns per input frame,
  command, and published frame, current RSS, peak RSS, published FPS, p95
  publication interval, and the last published revision;
- every `DisplayFramePublisherMetrics` counter;
- shared SurfaceStore damage, snapshot, copy-byte, materialization, lease,
  allocation, GPU error, and video-path counters;
- damage-plan topology: rectangles before/after merge and full-frame decisions
  attributed to rectangle count, covered area, an explicit full-damage marker,
  surface initialization, a new IOSurface slot, or a candidate older than the
  retained damage history. These describe revisioned IOSurface catch-up plans;
  the Data-only backend reports zero because it does not consume that path. The
  exact fields are `damage_rectangles_before_merge`,
  `damage_rectangles_after_merge`, `full_damage_by_count`,
  `full_damage_by_area`, `full_damage_by_explicit`,
  `full_damage_by_surface_initialization`, `full_damage_by_new_slot`, and
  `full_damage_by_history_gap`;
- explicit Data/revisioned path counters: Data snapshots, revisioned uploads,
  revision reuse, fallbacks, backing disables, and CPU catch-up copy bytes;
- wire, display, publisher, and renderer phase metric fields. They are zero,
  with sample period zero, in the performance matrix. With diagnostics enabled,
  bitmap validation, mutation, and damage-journal phases select the same one
  command out of every 64; snapshot checkout, damage planning, CPU copy, and
  finish phases sample every invocation. `sampled_nanoseconds` is the sum of
  selected samples, not an extrapolated total.

The enhanced HEAD benchmark gates the declared sampling periods and path
counts.
It also rejects RSS collection failures: current RSS must be nonzero and peak
RSS must be at least current RSS.
The Data-only backend must retain no IOSurface lease; CPU-IOSurface must retain
exactly the sink's latest consumer lease. With diagnostics enabled, all four
snapshot phase recorders use period one, and their sample counts must equal the
successful revisioned upload count (or zero on Data-only). A formal-sized
diagnostic run also rejects a zero-sample framer-append span. Revisioned upload
plus revision reuse must equal total snapshots when fallback is forbidden.
When the revisioned backend copies nonzero catch-up bytes, it requires nonempty
damage plans and never attributes more full plans than successful revisioned
uploads. Post-merge rectangles may not exceed input rectangles plus one
synthetic full-surface rectangle per full plan. An initial or new-slot full
plan can legitimately have zero input rectangles, while pending input counts
are preserved when they exist. A run with zero catch-up copy bytes must keep
all eight topology counters at zero; a successful zero-byte writable checkout
may still count as a revisioned upload.
The Data-only path also requires all eight counters to stay zero because it does
not consume revisioned damage plans.

`frames` is the deterministic number of input frames. Use
`publisher_emitted_frames` for published frames because the real 16 ms
publisher may coalesce revisions at scheduling boundaries. Compare optimized
builds on an otherwise idle host, use multiple fresh-process repetitions, and
do not treat a single local result as a production performance claim.
