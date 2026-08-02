# SwiftSpice and spice-client-glib2 Rocky performance results

Test date: 2026-08-02 (Asia/Singapore)

## Outcome

The intended formal CPU/Metal comparison at 1280x720 and 3840x2160 did not
produce a valid ten-pair performance verdict. The old guest reset implementation
repeatedly created xterm clients and eventually stopped producing display
activity. The runner correctly rejected the late samples using activity-span,
time-bucket, and last-frame-age gates. Therefore this report makes **no formal
non-inferiority claim**.

The first eight contiguous pairs from each fresh collection passed all evidence
gates. They are retained as diagnostics, not promoted to a formal result. All
four diagnostic prefixes failed CPU per published frame. The 4K Metal prefix
also failed RSS. Current performance work is therefore still required even
after the fixture is made fully reliable.

## Test contract

- Remote peer: disposable Rocky 9.8 host running QEMU/SPICE and the deterministic
  animation guest.
- Clients: current-tree arm64 Release `spice-probe` and
  `spice-client-glib-2.0` 0.42, connected separately to the same loopback-only
  endpoint through an SSH tunnel.
- Variants: CPU and required-Metal rendering at 1280x720 and 3840x2160.
- Formal shape: ten alternating paired runs, 30 seconds per client.
- Evidence gates: process exit zero, stable guest boot epoch within each pair,
  at least 80% active-span coverage, at least 8 of 10 active time buckets, and a
  last frame no more than one second before observation end.
- Metal gates: nonzero command-buffer and command counts, zero CPU
  materializations, and zero GPU errors.
- Decision gates: paired bootstrap confidence intervals for fps, ready-frame,
  p95 interval, CPU per published frame, and maximum RSS.

The runner's collect-on-failure mode retained all requested samples where
needed, but did not waive any evidence failure.

## Formal evidence disposition

| Variant | Fresh contiguous valid prefix | Late evidence failure | Formal disposition |
| --- | ---: | --- | --- |
| 720p CPU | 8 pairs | Pair 9 GLib became static; fail-fast collection stopped | **INVALID** |
| 720p Metal | 8 pairs | Pair 9 GLib and both pair 10 clients lacked activity | **INVALID** |
| 4K CPU | 8 pairs | Pair 9 GLib and both pair 10 clients lacked activity | **INVALID** |
| 4K Metal | 8 pairs | Pair 9 GLib and both pair 10 clients lacked activity | **INVALID** |

The invalid late samples were not removed to manufacture a ten-pair result.
Each eight-pair prefix below is explicitly diagnostic.

## Eight-pair diagnostic prefixes

| Variant | fps ratio, 95% CI | CPU/frame ratio, 95% CI | RSS ratio, 95% CI | Diagnostic outcome |
| --- | --- | --- | --- | --- |
| 720p CPU | 1.071789 [1.062116, 1.091480] | 1.468515 [1.401897, 1.529387] | 0.622250 | CPU/frame **FAIL** |
| 720p Metal | 1.086022 [1.079750, 1.097750] | 1.944140 [1.641716, 2.433767] | 0.741181 | CPU/frame **FAIL** |
| 4K CPU | 1.052541 [1.038564, 1.060013] | 1.375421 [1.196252, 1.685997] | 0.913699 | CPU/frame **FAIL** |
| 4K Metal | 1.076764 [1.060041, 1.083333] | 1.534300 [1.500911, 1.587459] | 1.256189 [1.255251, 1.264151] | CPU/frame and RSS **FAIL** |

All four prefixes passed the fps, ready-frame, and p95 gates. The first three
passed RSS. Passing individual metrics does not override either an evidence
failure or the failed CPU/frame gate.

### Absolute diagnostic medians

| Variant | Swift fps | GLib fps | Swift CPU/frame | GLib CPU/frame | Swift RSS | GLib RSS |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 720p CPU | 51.817 | 48.267 | 2.256 ms | 1.547 ms | 79.35 MB | 127.48 MB |
| 720p Metal | 52.033 | 48.050 | 2.413 ms | 1.225 ms | 94.63 MB | 127.70 MB |
| 4K CPU | 52.033 | 49.583 | 3.972 ms | 3.043 ms | 197.49 MB | 216.09 MB |
| 4K Metal | 53.467 | 49.417 | 5.779 ms | 3.691 ms | 271.49 MB | 216.12 MB |

## Metal lifecycle and hot-path evidence

All 20 measured Metal processes, ten at each resolution, exited zero. Valid
samples recorded zero GPU errors and zero CPU materializations. No process
reproduced the former active-encoder `endEncoding` abort, so the explicit
idempotent cancellation/finalization paths held under this workload.

Median counters per valid 30-second Metal sample were:

| Counter | 720p Metal | 4K Metal |
| --- | ---: | ---: |
| Batch-seed GPU copy | 5.77 GB | 53.25 GB |
| Snapshot catch-up CPU copy | 2.89 GB | 29.56 GB |
| Shared upload bytes | 271.67 MB | 319.51 MB |
| Upload-buffer allocations | 177.5 | 176.5 |
| Upload-buffer reuses | 85,700 | 92,097.5 |
| Metal command buffers | 1,565 | 1,605 |
| Metal commands | 85,844 | 92,248 |

The persistent upload pool is being reused heavily, while full-surface seed and
snapshot copies scale sharply at 4K. CPU opcode execution itself accounted for
only about 164 ms per 30 seconds at 720p and 136 ms at 4K in CPU mode. The next
investigation should therefore prioritize batch seeding, snapshot catch-up,
publisher scheduling, and full-frame copy policy before shader micro-tuning.

## Guest reset defect and repair

The old guest reset path recreated the xterm workload for every client. After
roughly 18 resets the guest could report `animation` while delivering only a
static frame. That violated the benchmark's equal-work contract.

The repaired guest image keeps one xterm and generator process. The
`control.sh reset` command now sends `SIGUSR1` to the generator, which returns
to frame zero without creating another X client. Short alternating stress after
this change produced:

| Fixture | Shape | Activity-valid samples | Reset path |
| --- | --- | ---: | --- |
| 1280x720 | 10 pairs x 5 seconds | 20/20 | 19 signal resets |
| 3840x2160 | 10 pairs x 5 seconds | 19/20 | 18 signal resets; one start fallback |

The single invalid 4K GLib sample published one frame, covered one of ten time
buckets, and ended 4.98 seconds before the observation cutoff. The permanent
late-batch staticization is fixed at 720p, but 4K is not yet reliable enough for
a formal rerun.

## Validation and retained evidence

After the code and fixture changes:

- `swift test --disable-sandbox -Xswiftc -warnings-as-errors` passed 347 tests
  in 68 suites on a full rerun.
- The focused Metal IOSurface mapping/blit test passed three consecutive runs
  after one earlier transient presenter failure.
- `uv run Benchmarks/test_analyze.py` passed all four analyzer tests.
- Shell syntax checks and `git diff --check` passed.
- Remote QEMU, temporary tickets, and the local SPICE tunnel were stopped after
  collection.

Local raw result directories are under `/private/tmp` and may be removed by the
operating system:

- `/private/tmp/swiftspice-signal-reset-720-stress-10x5`
- `/private/tmp/swiftspice-signal-reset-4k-stress-10x5`

Remote round evidence is retained under the fixture's `perf-ab/logs/` tree with
run IDs `20260802T021211Z`, `20260802T023733Z`, `20260802T024924Z`,
`20260802T030127Z`, `20260802T032742Z`, and `20260802T033108Z`.

## Next formal gate

1. Make the repaired 4K fixture pass all 20 samples in a ten-pair, five-second
   activity stress run.
2. Start a fresh guest epoch and collect all four ten-pair, 30-second variants.
3. Reject the entire affected batch on any process, epoch, activity, or Metal
   evidence failure.
4. Treat CPU/frame <= 1.10 and 4K Metal RSS <= 1.15 as unresolved performance
   requirements; the diagnostic prefixes currently miss them.
