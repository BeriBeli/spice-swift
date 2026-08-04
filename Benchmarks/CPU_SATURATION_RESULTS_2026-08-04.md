# CPU saturation A/B results — 2026-08-04

## Decision

Two independently collected formal same-harness batches do **not** justify a
general CPU-speedup or memory-reduction claim for the
`ChannelSerialBarrier.record()` empty-waiter fast path. The independent rerun
does detect a narrow 4K CPU decrease, but the original 4K batch did not. At
720p, neither batch detects a reliable change and their point estimates have
opposite directions. RSS is unchanged within uncertainty in both batches.

The 4K rerun is therefore evidence of a possible small benefit that still
needs an independent confirming batch before it is described as replicated.
It is not evidence of a production GUI speedup.

The primary metric is ingest process CPU per command. Ratios are paired
optimized/baseline ratios, so a value below 1 favors the optimized commit.

| Batch | Resolution | Baseline median | Optimized median | Paired median ratio | 95% bootstrap CI | Result |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| Original | 720p | 1,629 ns/command | 1,625 ns/command | 0.9957108 | [0.9898492, 1.0012315] | No reliable change |
| Rerun | 720p | 1,683 ns/command | 1,687.5 ns/command | 1.0035642 | [0.9946524, 1.0074608] | No reliable change |
| Original | 4K | 1,643.5 ns/command | 1,636 ns/command | 0.9984765 | [0.9921191, 1.0012203] | No reliable change |
| Rerun | 4K | 1,699.5 ns/command | 1,684.5 ns/command | 0.9905715 | [0.9868002, 0.9952964] | Decrease detected |

The original 720p point estimate is 0.43% lower, while the rerun is 0.36%
higher; both intervals include 1. The original 4K point estimate is 0.15%
lower with an interval that includes 1, while the rerun is 0.94% lower with an
interval wholly below 1. Both 4K point estimates favor the optimized commit,
but only one batch crosses the decision threshold. No post-hoc pooled interval
is used: each predeclared ten-pair batch stands on its own. The median of the
paired ratios is the decision statistic; it is not the ratio of the two
unpaired medians.

End-to-end CPU, which includes the single final publication drain, reaches the
same conclusion:

| Batch | Resolution | Paired median ratio | 95% bootstrap CI | Result |
| --- | --- | ---: | ---: | --- |
| Original | 720p | 0.9960060 | [0.9895732, 1.0006150] | No reliable change |
| Rerun | 720p | 1.0038590 | [0.9952494, 1.0071557] | No reliable change |
| Original | 4K | 0.9978801 | [0.9927612, 1.0003017] | No reliable change |
| Rerun | 4K | 0.9911893 | [0.9868542, 0.9956140] | Decrease detected |

Current and peak RSS were identical within each sample and also show no
reliable change:

| Batch | Resolution | Baseline RSS median | Optimized RSS median | Paired median ratio | 95% bootstrap CI | Result |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| Original | 720p | 37.390625 MiB | 37.328125 MiB | 0.9997894 | [0.9962515, 1.0029255] | No reliable change |
| Rerun | 720p | 37.492188 MiB | 37.468750 MiB | 1.0000001 | [0.9972936, 1.0012542] | No reliable change |
| Original | 4K | 93.632813 MiB | 93.617188 MiB | 0.9999166 | [0.9990826, 1.0009181] | No reliable change |
| Rerun | 4K | 93.695313 MiB | 93.656250 MiB | 0.9996666 | [0.9988330, 1.0005841] | No reliable change |

These process-level saturation measurements do not establish the memory or
latency effect of a production GUI session.

## Exact comparison boundary

- Baseline commit:
  `932a4e575df4252f16276ce7985db022f6e2e21b`
- Optimized commit and tool commit:
  `91ec86784bba19b1971bbdc5fd11ffc76b9f1118`
- Common benchmark harness SHA-256:
  `6556add72637b01bb710c2a73df32e05d9ce67c8f0467dff12fbe295bdbfc886`
- Runner SHA-256:
  `5eef2c6d04f9a15798aeeeb1be1873783e9675c2b90adbe03763f3828572caf0`
- Analyzer SHA-256:
  `935e25a0069f0079d95b75e0f7e760196f6bc73c24463befb0284c2492744078`
- Host: Mac16,8, Apple M4 Pro, arm64, macOS 26.6 (25G72)
- Toolchain: Xcode 26.6 (17F113), Swift 6.3.3
  (swiftlang 6.3.3.1.3, clang 2100.1.1.101)
- Host boot: epoch `1785654095`, 2026-08-02 07:01:35 UTC
- Original run window: 2026-08-04 08:52:46–08:53:32 UTC
- Independent rerun window: 2026-08-04 14:41:37–14:42:26 UTC

The baseline and optimized commits use the byte-identical benchmark harness
above. Their only source difference is the three-line early return after
updating the latest serial when `ChannelSerialBarrier` has no waiters. Future
waiters still observe the recorded serial. This experiment isolates that
fast path; it does not measure the broader CPU-hot-path changes in the parent
PR.

## Protocol and acceptance gates

Each batch has its own continuous attempt ledger containing 44 fresh Release
processes with zero failures: four balanced warm-up attempts followed by 40
formal samples. Across both batches this is 88 attempts, 80 formal samples,
and eight discarded warm-ups. In each batch, each resolution has ten pairs,
split evenly between baseline-first and optimized-first order. No attempt was
omitted or replaced.

Every sample uses:

- the `cpu-iosurface` backend in saturation mode with diagnostics disabled;
- 6,000 input frames and 57 RAW xRGB bitmap commands per frame;
- exactly 342,000 commands per process;
- 1280×720 or 3840×2160 destination geometry;
- no input pacing and no automatic publication during ingest;
- exactly one explicit final publication drain.

The analyzer rejects samples with the wrong schema, workload, commit, harness,
pair order, process identity, or attempt count. Runtime gates require exact
command/revision/copy-byte accounting, one snapshot and one emitted frame, and
zero fallback, GPU, compositor, native-video, materialization, stale-output,
or pre-drain publication activity.

The reported 95% intervals are deterministic percentile bootstraps of 100,000
resamples of the ten within-pair ratios. The primary seeds are `720202604` for
720p and `420260804` for 4K.

## Validation

The optimized source passed the complete host-side Swift suite outside the
Codex sandbox with warnings treated as errors:

```sh
swift test --disable-sandbox -Xswiftc -warnings-as-errors
```

Result: 376 tests in 71 suites passed.

The Python analyzer unit suite passed 12 tests. Each evidence analyzer also
re-extracted every sample from its retained process log, validated its
continuous attempt ledger and canonical 54-file SHA-256 manifest, and
recomputed `stats.json` successfully:

```sh
uv run --no-project \
  Benchmarks/Results/CPUSaturation_2026-08-04/tools/analyze_cpu_saturation.py \
  Benchmarks/Results/CPUSaturation_2026-08-04 --check

uv run --no-project \
  Benchmarks/Results/CPUSaturation_2026-08-04-rerun/tools/analyze_cpu_saturation.py \
  Benchmarks/Results/CPUSaturation_2026-08-04-rerun --check
```

## Scope and next step

This saturation A/B targets fixed per-command CPU overhead. It does not measure
16 ms publication cadence, interactive latency, AppKit presentation, a live
SPICE session, GLib, Metal rendering, native video, or VideoToolbox. The
single final drain is included only in the secondary end-to-end metric.

The two batches bound this fast path as a small and resolution-dependent
effect. The 4K rerun is worth retaining as a signal, but the lack of a crossing
interval in the original 4K batch and the unreplicated 720p result rule out a
general speedup claim. The next CPU work should remain focused on larger sites:
publisher coalescing/timer lifetime, SurfaceStore actor and ownership costs,
and direct batched IOSurface mutation.

## Original artifacts

- [all 44 attempts](Results/CPUSaturation_2026-08-04/attempts.jsonl)
- [four discarded warm-ups](Results/CPUSaturation_2026-08-04/warmups.jsonl)
- [720p formal samples](Results/CPUSaturation_2026-08-04/formal_720p.jsonl)
- [4K formal samples](Results/CPUSaturation_2026-08-04/formal_4k.jsonl)
- [host, toolchain, commit, harness, and execution metadata](Results/CPUSaturation_2026-08-04/metadata.json)
- [paired bootstrap statistics and attempt audit](Results/CPUSaturation_2026-08-04/stats.json)
- [canonical 54-file SHA-256 manifest](Results/CPUSaturation_2026-08-04/SHA256SUMS)
- [exact analyzer used for the run](Results/CPUSaturation_2026-08-04/tools/analyze_cpu_saturation.py)
- [exact runner used for the run](Results/CPUSaturation_2026-08-04/tools/run_cpu_saturation_ab.py)

## Independent rerun artifacts

- [all 44 rerun attempts](Results/CPUSaturation_2026-08-04-rerun/attempts.jsonl)
- [four discarded rerun warm-ups](Results/CPUSaturation_2026-08-04-rerun/warmups.jsonl)
- [rerun 720p formal samples](Results/CPUSaturation_2026-08-04-rerun/formal_720p.jsonl)
- [rerun 4K formal samples](Results/CPUSaturation_2026-08-04-rerun/formal_4k.jsonl)
- [rerun metadata](Results/CPUSaturation_2026-08-04-rerun/metadata.json)
- [rerun paired statistics and attempt audit](Results/CPUSaturation_2026-08-04-rerun/stats.json)
- [rerun canonical 54-file SHA-256 manifest](Results/CPUSaturation_2026-08-04-rerun/SHA256SUMS)
- [exact rerun analyzer](Results/CPUSaturation_2026-08-04-rerun/tools/analyze_cpu_saturation.py)
- [exact rerun runner](Results/CPUSaturation_2026-08-04-rerun/tools/run_cpu_saturation_ab.py)
