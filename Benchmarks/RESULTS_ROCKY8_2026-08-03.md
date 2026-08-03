# SwiftSpice PR #4 Rocky performance results

Test date: 2026-08-03 (Asia/Singapore)

Tested head: `d68a8ec7502421b5bd5bdfa16804ea2b839a7a63`

## Outcome

The requested CPU and Metal 1280x720/3840x2160 collections ran to completion
as ten alternating 30-second pairs, including collection after evidence
failures. None produced a formal ten-pair verdict: the guest workload stopped
delivering display activity in late samples, and `integrity-failures.tsv`
correctly caused the analyzer to reject every complete batch.

Activity-valid pairs are retained only as diagnostics. All four diagnostic
sets passed fps, ready-frame, and p95 interval gates. Every set failed the
CPU-per-published-frame gate; 4K Metal also failed RSS. This report therefore
makes no non-inferiority or Metal-benefit claim.

Metal lifecycle and renderer-selection evidence was clean. All 20 Metal
processes exited zero, submitted Metal work, and recorded zero supported CPU
opcodes, Metal-to-CPU fallback operations, CPU materializations, GPU errors,
and pool exhaustions.

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
- Metal gates: completed command buffers and commands; zero supported CPU
  opcodes, dedicated Metal-to-CPU fallback operations, CPU materializations,
  GPU errors, and pool exhaustions.
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

## Metal lifecycle and data-movement evidence

Median counters per activity-valid 30-second Metal sample were:

| Counter | 720p Metal | 4K Metal |
| --- | ---: | ---: |
| Batch-seed GPU copy | 5.65 GB | 53.91 GB |
| Snapshot catch-up CPU copy | 2.44 GB | 30.34 GB |
| Shared upload bytes | 268.95 MB | 319.31 MB |
| Upload-buffer allocations | 183 | 163.5 |
| Upload-buffer reuses | 84,800 | 92,071.5 |
| Metal command buffers | 1,533 | 1,625 |
| Metal commands | 84,956 | 92,221.5 |
| Completed GPU time | 1.99 s | 2.71 s |

The batch-seed counter precisely matches one full-surface clone per command
buffer: `1280 * 720 * 4 * 1533 = 5,651,251,200` bytes and
`3840 * 2160 * 4 * 1625 = 53,913,600,000` bytes. Snapshot requests flush a
pending batch, so command-buffer count remains close to published-frame count.
Each new batch then clones the full canonical IOSurface before applying its
commands. Snapshot catch-up performs a second large CPU-to-IOSurface transfer
when the writable revision is behind the damage journal.

The persistent upload pool is effective: allocations are small relative to
roughly 85,000-92,000 reuses. CPU opcode bodies accounted for a median of only
120 ms per 30 seconds at 720p and 91 ms at 4K in CPU mode. Optimization should
therefore prioritize full-surface batch seeding, snapshot catch-up, publication
flush frequency, and generation policy before shader or CPU-opcode tuning.

## Guest activity defect

Before the 30-second collections, a fresh 4K fixture passed all 20 samples in a
ten-pair, five-second activity stress. The longer batches nevertheless became
static late in the collection. `control.sh reset` continued to report
`PERF_LOAD state=animation reset_frame=0`, but both clients eventually received
an incomplete or single-frame window. Sending `control.sh start` after the
degraded state also failed to restore sustained activity.

The common failure across CPU, Metal, SwiftSpice, GLib, 720p, and 4K identifies
the xterm-based guest fixture as the evidence blocker rather than a renderer
failure. A persistent native X11 generator should replace the xterm workload
before another formal ten-pair run.

## Retained evidence and cleanup

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
   samples in both short stress and full-duration preflight coverage.
2. Re-run the historical `cpu` versus GLib 10x30-second reference at both
   resolutions under a fresh boot epoch.
3. Add a direct Swift renderer-pair runner/analyzer and compare `cpu-iosurface`
   with `metal` under the same guest epoch and alternating order.
4. Preserve the existing pure-Metal evidence gates and reject the entire batch
   on any process, epoch, activity, backing, fallback, or GPU failure.
5. Treat CPU/frame <= 1.10 and 4K Metal RSS <= 1.15 as unresolved requirements.
