# SwiftSpice PR #4 Rocky performance results

Test date: 2026-08-03 (Asia/Singapore)

Tested head: `d68a8ec7502421b5bd5bdfa16804ea2b839a7a63`

## Outcome

The requested CPU and Metal 1280x720/3840x2160 collections ran to completion
as ten alternating 30-second pairs, including collection after evidence
failures. None produced a formal ten-pair verdict: observed display activity
stopped in late samples, and `integrity-failures.tsv`
correctly caused the analyzer to reject every complete batch.

Activity-valid pairs are retained only as diagnostics. All four diagnostic
sets passed fps, ready-frame, and p95 interval gates. Every set failed the
CPU-per-published-frame gate; 4K Metal also failed RSS. This report therefore
makes no non-inferiority or Metal-benefit claim.

Metal lifecycle and renderer-selection evidence was clean for the four 2D
opcodes that the candidate supports: fill, COPY_BITS, bitmap copy, and surface
copy. All 20 Metal processes exited zero, submitted Metal work, and recorded
zero executions of those CPU opcodes, Metal-to-CPU fallback operations, CPU
materializations, GPU errors, and pool exhaustions. Scaled copy is not part of
that pure-Metal gate because the candidate does not implement it; this
particular workload also recorded zero scaled-copy operations, as detailed
below.

## Test contract

- Remote peer: loopback-only Rocky 9.8 QEMU/SPICE endpoint with the
  deterministic animation guest.
- Clients: arm64 Release `spice-probe` from the tested head and
  `spice-client-glib-2.0` 0.42, connected separately through an SSH tunnel.
- Variants: Data-backed CPU and required-revisioned Metal at 1280x720 and
  3840x2160.
- Requested shape: ten alternating paired runs, 30 seconds per client.
- Activity gates: process exit zero, one stable guest boot epoch within each
  pair, at least 80% active-span coverage, at least 8 of 10 active time buckets,
  and a last frame no more than one second before observation end.
- Metal gates: completed command buffers and commands; zero CPU executions of
  the four currently supported opcodes (fill, COPY_BITS, bitmap copy, and
  surface copy), dedicated Metal-to-CPU fallback operations, CPU
  materializations, GPU errors, and pool exhaustions. Scaled copy is outside
  this gate.
- Performance gates: paired bootstrap confidence intervals for fps,
  ready-frame, p95 interval, CPU per published frame, and maximum RSS.

`SWIFTSPICE_BENCH_CONTINUE_ON_FAILURE=1` retained all requested samples but did
not waive any evidence gate. Metal and IOSurface execution, builds, and tests
ran on the macOS host rather than in a filesystem sandbox.

### Configuration limitation

The `cpu` configuration uses CPU drawing with Data backing. The `metal`
configuration uses Metal 2D with revisioned IOSurface backing. They were
collected in separate batches and therefore do not isolate the Metal draw
engine. A Metal benefit claim still requires a direct paired runner comparing
`cpu-iosurface` with `metal` under the same boot epoch, reset sequence,
resolution, and order schedule.

The PR now includes a dedicated
[`run_renderer_pairs.sh`](run_renderer_pairs.sh) collection runner and
[`analyze_renderer_pairs.py`](analyze_renderer_pairs.py) analyzer for that
comparison. They were added after this collection and have not been used for a
host run, so they provide no direct `cpu-iosurface` versus `metal` result yet.
For future formal evidence the direct runner requires matching guest boot IDs
before and after every sample, rejects any Metal scaled-copy CPU work and any
cpu-iosurface materialization, and then requires one boot epoch, codec, and
resolution across the complete alternating batch.

## Formal evidence disposition

| Variant | Complete activity-valid pairs | Rejected samples | Formal disposition |
| --- | --- | --- | --- |
| 720p CPU | 1-8 (8 pairs) | Pair 9 and 10, both clients | **INVALID** |
| 720p Metal | 1-5, 7-8 (7 pairs) | Pair 6 Swift, pair 9 GLib, pair 10 both clients | **INVALID** |
| 4K CPU | 1-8 (8 pairs) | Pair 9 GLib, pair 10 both clients | **INVALID** |
| 4K Metal | 1-8 (8 pairs) | Pair 9 GLib, pair 10 both clients | **INVALID** |

Every measured process exited zero, and each complete batch remained within
one boot epoch. The rejected samples failed activity coverage rather than
process, epoch, or renderer-evidence checks. Invalid samples remain in the raw
directories; valid-pair copies exist only to make the diagnostic calculation
reproducible.

## Activity-valid paired diagnostics

Ratios are SwiftSpice divided by spice-client-glib2. Higher is better for fps;
lower is better for every other metric.

| Variant | fps ratio, 95% CI | Ready ratio, 95% CI | p95 ratio, 95% CI | CPU/frame ratio, 95% CI | RSS ratio, 95% CI |
| --- | --- | --- | --- | --- | --- |
| 720p CPU (8) | 1.057383 [1.034529, 1.077503] | 0.680707 [0.656451, 0.763762] | 0.666541 [0.653332, 0.676547] | **1.313759 [1.265321, 1.524827]** | 0.620605 [0.618704, 0.622399] |
| 720p Metal (7) | 1.054520 [1.042120, 1.074595] | 0.760709 [0.746893, 0.861906] | 0.682718 [0.675967, 0.692185] | **2.174098 [1.913191, 2.426400]** | 0.740827 [0.738456, 0.741279] |
| 4K CPU (8) | 1.050522 [1.028840, 1.053523] | 0.798905 [0.737264, 0.842208] | 0.783850 [0.771761, 0.790430] | **1.107982 [0.926811, 1.348702]** | 0.913879 [0.912644, 0.920381] |
| 4K Metal (8) | 1.093200 [1.071334, 1.104871] | 0.907328 [0.863541, 0.965481] | 0.774421 [0.742762, 0.803537] | **1.811612 [1.398216, 2.243931]** | **1.255131 [1.250421, 1.257216]** |

Bold values fail the applicable upper-bound gate. Passing individual metrics
does not override an incomplete formal batch.

### Absolute diagnostic medians

| Variant | Swift fps | GLib fps | Swift CPU/frame | GLib CPU/frame | Swift RSS | GLib RSS |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 720p CPU | 51.867 | 48.867 | 1.788 ms | 1.502 ms | 79.10 MB | 127.33 MB |
| 720p Metal | 50.933 | 47.967 | 3.216 ms | 1.425 ms | 94.27 MB | 127.25 MB |
| 4K CPU | 51.900 | 49.450 | 2.917 ms | 2.950 ms | 197.20 MB | 215.90 MB |
| 4K Metal | 54.100 | 49.283 | 3.668 ms | 2.055 ms | 271.25 MB | 216.14 MB |

Separate absolute medians are descriptive only; the gate uses paired ratios.

## Renderer and data-movement evidence

Median counters per activity-valid 30-second Metal sample were:

| Counter | 720p Metal | 4K Metal |
| --- | ---: | ---: |
| Batch-seed GPU copy | 5.65 GB | 53.91 GB |
| Initial batch-seed CPU copy | 3.69 MB | 33.18 MB |
| Snapshot catch-up CPU copy | 2.44 GB | 30.34 GB |
| Shared upload bytes | 268.95 MB | 319.31 MB |
| Upload-buffer allocations | 183 | 163.5 |
| Upload-buffer reuses | 84,800 | 92,071.5 |
| Metal command buffers | 1,533 | 1,625 |
| Metal commands | 84,956 | 92,221.5 |
| Published frames | 1,528 | 1,623 |
| Metal 2D draw-batch GPU time | 1.99 s | 2.71 s |

The batch-seed counter precisely matches one full-surface clone per command
buffer: `1280 * 720 * 4 * 1533 = 5,651,251,200` bytes and
`3840 * 2160 * 4 * 1625 = 53,913,600,000` bytes. Snapshot requests flush a
pending batch, so command-buffer count remains close to published-frame count.
Each new batch then clones the full canonical IOSurface before applying its
commands. Snapshot catch-up performs a second large CPU-to-IOSurface transfer
when the writable revision is behind the damage journal.

Ratios below are derived from the median counters above. They are diagnostic,
not formal performance gates.

| Derived ratio | 720p Metal | 4K Metal |
| --- | ---: | ---: |
| Command buffers / published frame | 1.0033 | 1.0012 |
| Commands / command buffer | 55.418 | 56.752 |
| Catch-up bytes / command buffer | 1,594,313.9 B | 18,671,332.4 B |
| Catch-up / one full frame per command buffer | 43.2485% | 56.2769% |
| Catch-up bytes / published frame | 1,599,530.9 B | 18,694,340.9 B |
| Catch-up / one full frame per published frame | 43.3901% | 56.3463% |
| Recorded draw-batch GPU time / command buffer | 1.298 ms | 1.665 ms |

Summing those median counters, the three sustained payload paths plus one
initial CPU seed account for:

```text
720p: 5,651,251,200 + 3,686,400 + 2,444,083,200 + 268,945,792
     = 8,367,966,592 bytes / 30 s = 0.279 GB/s

4K:   53,913,600,000 + 33,177,600 + 30,340,915,200 + 319,308,672
     = 84,607,001,472 bytes / 30 s = 2.820 GB/s
```

These are payload-byte counters, not total memory-bus traffic: they count each
payload once rather than both its source read and destination write, and omit
shader destination writes, presentation, and cache-coherence traffic.

### GPU-time scope

`metal_2d_gpu_time_ns` measures only the `SpiceMetal2DBatch` command buffer by
subtracting its `gpuStartTime` from `gpuEndTime`. The full-surface seed blit is
submitted through the revision pool's separate command queue; that path waits
for completion and records bytes and success, but not GPU time. The metric also
excludes CPU upload/catch-up copies, command encoding and waits, Metal
presentation, and any other command queues. The 1.99 s and 2.71 s values
therefore must not be presented as total GPU time or GPU utilization.

### Actual opcode mix

The pure-Metal evidence gate intentionally covers only the four currently
supported opcodes. The activity-valid samples had the following CPU opcode
medians (`operations / nanoseconds`):

| CPU opcode | 720p CPU | 720p Metal | 4K CPU | 4K Metal |
| --- | ---: | ---: | ---: | ---: |
| Fill | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |
| COPY_BITS | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |
| Bitmap copy | 84,883.5 / 120,272,401.5 | 0 / 0 | 93,459 / 90,961,321 | 0 / 0 |
| Surface copy | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |
| Scaled copy | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |

All 84,956 and 92,221.5 median Metal commands were bitmap-copy commands; fill,
COPY_BITS, and surface-copy command counts were zero. `native_video_frames`,
`vt_decoded_frames`, and `advanced_cpu_fallback_frames` were also zero in every
activity-valid sample. Although the requested codec was MJPEG, this xterm
workload did not exercise a video stream or `drawScaledCopy`. The large
snapshot catch-up counter therefore cannot be attributed to MJPEG scaled copy;
the current counters establish the copy volume but do not identify its damage
source.

The complete median copy counters were:

| Counter | 720p CPU | 720p Metal | 4K CPU | 4K Metal |
| --- | ---: | ---: | ---: | ---: |
| Damage operations | 84,883.5 | 84,976 | 93,459 | 92,234.5 |
| Damage bytes | 268,424,576 | 269,004,160 | 321,780,672 | 319,340,544 |
| Full-frame CPU copy bytes | 5,761,843,200 | 3,686,400 | 51,657,523,200 | 33,177,600 |
| Partial-frame CPU copy bytes | 0 | 2,444,083,200 | 0 | 30,340,915,200 |
| Snapshot catch-up CPU copy bytes | 0 | 2,444,083,200 | 0 | 30,340,915,200 |
| Revision GPU copy bytes | 0 | 5,651,251,200 | 0 | 53,913,600,000 |
| Shared Metal upload bytes | 0 | 268,945,792 | 0 | 319,308,672 |

Every activity-valid CPU sample performed exactly one full-frame publication
copy per snapshot. Thus the low measured CPU-opcode body times (120 ms at 720p
and 91 ms at 4K) do not include 5.76 GB and 51.66 GB of full-frame publication
copying. Optimization should prioritize publication copies, full-surface Metal
batch seeding, snapshot catch-up, flush frequency, and revision generation
before shader or CPU-opcode body tuning. The persistent upload pool itself is
effective: allocations remain small relative to roughly 85,000-92,000 reuses.

### RSS and pool scope

The CPU and Metal configurations change both the renderer and backing policy.
The final diagnostic counters show that Metal retained the same Data surface
budget plus a two-frame revisioned IOSurface ring:

| Median counter | 720p CPU | 720p Metal | 4K CPU | 4K Metal |
| --- | ---: | ---: | ---: | ---: |
| Maximum RSS | 79,101,952 B | 94,273,536 B | 197,197,824 B | 271,253,504 B |
| Data surface allocated | 3,686,400 B | 3,686,400 B | 33,177,600 B | 33,177,600 B |
| Revisioned frames | 0 | 2 | 0 | 2 |
| Revisioned allocated | 0 | 7,372,800 B | 0 | 66,355,200 B |
| Total IOSurface allocated | 3,686,400 B | 7,372,800 B | 33,177,600 B | 66,355,200 B |
| Metal device current allocated | 0 | 9,273,344 B | 0 | 68,059,136 B |
| In-flight leases at observation end | 0 | 0 | 0 | 0 |
| Pool exhaustions | 0 | 0 | 0 | 0 |

At 4K the absolute Metal-minus-CPU RSS difference is 74,055,680 B
(70.625 MiB), while the end-of-observation IOSurface difference is one frame,
33,177,600 B (31.641 MiB). The configured revision-ring ceiling is three
frames, but these samples observed two. `metal_current_allocated_bytes` is a
device-wide diagnostic that can overlap IOSurface-backed resources and must not
be added to RSS or IOSurface bytes. These counters support backing-policy and
Metal-resource overhead as important contributors, but they cannot isolate the
Metal 2D renderer. A direct `cpu-iosurface` versus `metal` comparison remains
required.

## Guest activity evidence gap

Before the 30-second collections, a fresh 4K fixture passed all 20 samples in a
ten-pair, five-second activity stress. The longer batches nevertheless became
static late in the collection. `control.sh reset` continued to report
`PERF_LOAD state=animation reset_frame=0`, but both clients eventually received
an incomplete or single-frame window. Sending `control.sh start` after the
degraded state also failed to restore sustained activity.

The common late failure across CPU, Metal, SwiftSpice, GLib, 720p, and 4K
strongly suggests a fixture problem, but the collection did not retain an
independent guest generator counter or X11 Present/Damage telemetry. In
particular, 720p Metal pair 6 rejected only the Swift sample while the paired
GLib sample remained active. A successful `control.sh reset` reports the
control-plane action, not continued generator progress during the following 30
seconds. The evidence therefore cannot assign every rejected sample, or pair 6
specifically, to the guest rather than a downstream server, transport, or
client path.

The formal blocker is an unlocalized activity-evidence failure. A guest-side
generation/frame heartbeat has been added for future collection, but those
counters were not present in these results and have not yet been exercised by a
replacement formal batch. Replacing the xterm workload with a persistent native
X11 generator remains a recommended fixture improvement.

## Retained evidence and cleanup

The durable sanitized evidence is the repository's
[`swiftspice-pr4-d68a8ec-rocky-results.tar.gz`](Results/2026-08-03/swiftspice-pr4-d68a8ec-rocky-results.tar.gz),
documented in its [README](Results/2026-08-03/README.md) and accompanied by a
[checksum file](Results/2026-08-03/swiftspice-pr4-d68a8ec-rocky-results.tar.gz.sha256).
Its verified SHA-256 is
`b71b301b6cf3d5e374055681a928ffdee2b3073e2e0d1fe5c5d56b296e5c2b18`
(115,127 bytes).

The archive contains the four complete raw batches, the four activity-valid
diagnostic selections, and the 4K ten-pair five-second stress set. It preserves
all JSON, metadata, and `/usr/bin/time` samples, integrity failures, analyzer
output and exit status, the exact tested analyzer and live runner, a manifest,
and per-file SHA-256 checksums. It excludes the repeated generated GLib binary;
the archived structured files contain no SPICE password, ticket, token,
authorization field, endpoint, or local user path.

Local raw directories:

- `/private/tmp/swiftspice-pr4-d68a8ec-cpu-glib-720p-10x30-20260803`
- `/private/tmp/swiftspice-pr4-d68a8ec-metal-glib-720p-10x30-20260803`
- `/private/tmp/swiftspice-pr4-d68a8ec-cpu-glib-4k-10x30-20260803`
- `/private/tmp/swiftspice-pr4-d68a8ec-metal-glib-4k-10x30-20260803`
- `/private/tmp/swiftspice-pr4-d68a8ec-4k-stress-10x5-20260803`

Diagnostic copies contain only complete activity-valid pairs and are named
`*-valid7-*` or `*-valid8-*` beside the raw directories.

Remote run IDs under the fixture's `perf-ab/logs/` tree are
`20260803T112858Z`, `20260803T113443Z`, `20260803T114653Z`,
`20260803T115921Z`, and `20260803T121520Z`.

The remote QEMU endpoint was stopped, its temporary ticket was removed, and the
local SPICE tunnel was closed after collection. The PR and main worktrees were
clean before this documentation update.

## Next formal gate

1. Replace or repair the guest renderer and require 20/20 activity-valid
   samples in both short stress and full-duration preflight coverage, using the
   new guest generation/frame heartbeat to localize any stall.
2. Re-run the historical `cpu` versus GLib 10x30-second reference at both
   resolutions under a fresh boot epoch.
3. Run the newly added direct Swift renderer-pair runner/analyzer and compare
   `cpu-iosurface` with `metal` under the same guest epoch, resolution, reset
   sequence, and alternating order. The tooling exists, but no such collection
   has run yet.
4. Preserve the existing four-opcode Metal evidence gates and reject the entire
   batch on any process, epoch, activity, backing, fallback, or GPU failure.
5. Treat CPU/frame <= 1.10 and 4K Metal RSS <= 1.15 as unresolved requirements.
