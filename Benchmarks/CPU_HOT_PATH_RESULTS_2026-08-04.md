# CPU display hot-path results — 2026-08-04

## Decision

The final same-harness formal A/B does **not** detect a reliable process-CPU
change at either resolution. This PR must not be described as a production
speedup.

| Resolution | Baseline CPU/frame median | Optimized CPU/frame median | Paired median optimized/baseline | 95% bootstrap CI | Result |
| --- | ---: | ---: | ---: | ---: | --- |
| 720p | 0.860146 ms | 0.850023 ms | 0.9574316022 | [0.8745996664, 1.0239943787] | No reliable change |
| 4K | 0.788689 ms | 0.784883 ms | 1.0234382521 | [0.8885933150, 1.1247570182] | No reliable change |

The paired CPU ratios vary widely: 0.682240–1.712542 at 720p and
0.792131–1.206455 at 4K. Both confidence intervals cross 1, so neither point
estimate is evidence of a CPU reduction or regression. The primary statistic
is the median of within-pair optimized/baseline ratios, not the ratio of the two
unpaired sample medians.

The same formal population detects a small RSS increase:

| Resolution | Baseline RSS median | Optimized RSS median | Paired median optimized/baseline | 95% bootstrap CI | Result |
| --- | ---: | ---: | ---: | ---: | --- |
| 720p | 40.671875 MiB | 41.054688 MiB | 1.00922545 | [1.00769230, 1.01075820] | Increase detected |
| 4K | 125.132813 MiB | 125.421875 MiB | 1.00243586 | [1.00187149, 1.00324675] | Increase detected |

These ratios correspond to about 0.92% at 720p and 0.24% at 4K. Peak RSS has
the same direction; its exact statistics remain in `stats.json`. This local
process measurement does not establish the memory effect of a GUI session.
Published-frame count, wall time, and p95 publication interval all have
confidence intervals crossing 1.

The byte-identical-harness Release test executable grew from 13,783,496 to
14,359,208 bytes (+575,712 bytes) between the two implementations. Resident
code may therefore explain some or all of this sub-MiB process RSS movement,
but the experiment does not isolate that cause and says nothing definitive
about an application binary.

## Exact formal comparison boundary

- Baseline: `24d780d5dea98d969e3a38f300c5ffdc3f856655`
- Optimized: `60b73098a4aa8ad704dcd55a460280f1999fc2e2`
- Common formal benchmark SHA-256:
  `a9626003badd7d56afac0297c67edefbe0e8a65c4a82664c589e383b11a58b65`
- Host: Apple M4 Pro, arm64, macOS 26.6 (25G72)
- Toolchain: Swift 6.3.3, swiftlang 6.3.3.1.3, clang 2100.1.1.101
- Formal run window: 2026-08-04 00:07:22–00:31:11 UTC

Both commits ran the byte-identical baseline-compatible harness above. The
earlier comparison between different harnesses is superseded and is not used in
this decision.

The attempt ledger contains 44 continuous, timestamp-ordered fresh-process
attempts: four discarded warm-ups and 40 formal samples (ten pairs per
resolution). All 44 exited successfully. No failed, slow, fast, or otherwise
unfavorable attempt was omitted or replaced. Each resolution used five
baseline→optimized and five optimized→baseline pairs.

## Workload and acceptance gates

Every formal sample explicitly selected `cpu-iosurface`, with diagnostics
disabled, and ran:

- 1,500 input frames and 85,500 RAW xRGB bitmap commands;
- 57 commands per input frame;
- 32×25 pixels and exactly 3,200 payload bytes per command;
- 1280×720 or 3840×2160 destination geometry;
- a 16 ms paced input/publication interval;
- one retained consumer IOSurface lease.

The analyzer rejects a sample unless the workload identity, commit, harness,
pair order, and run ledger match exactly. Runtime gates also require the final
revision and all command/damage counts, snapshot attempts = emitted frames =
snapshots, two revisioned frames, exact two-buffer full-copy bytes, nonzero
partial-copy bytes, valid RSS/CPU/wall values, and zero stale snapshots, pending
evictions, pool exhaustion, GPU/compositor errors, CPU materialization, and
native-video activity.

The primary 95% interval is a deterministic percentile bootstrap of 100,000
resamples of the ten paired ratios, using sorted indexes 2,500 and 97,500. The
CPU/frame seeds are `720202604` and `420260804`; seeds for the remaining metrics
are recorded in `stats.json`.

Re-run every provenance and acceptance gate, then recompute the statistics,
with:

```sh
uv run --no-project Benchmarks/analyze_cpu_hotpath.py \
  Benchmarks/Results/CPUHotPath_2026-08-04 --check
```

## Order sensitivity

CPU/frame paired medians change materially with execution order:

| Resolution | Baseline→optimized median B/A | Optimized→baseline median B/A | RSS baseline→optimized median B/A | RSS optimized→baseline median B/A |
| --- | ---: | ---: | ---: | ---: |
| 720p | 1.0177563896 | 0.9530229034 | 1.0091918805 | 1.0092307692 |
| 4K | 1.0219749462 | 1.0510753725 | 1.0026217228 | 1.0019977525 |

The 720p CPU direction flips with order, while the 4K groups both have medians
above 1 but retain large within-group variation. Balanced ordering reduces
systematic drift; it cannot remove host scheduling noise. All pairs, including
the extreme ratios, are retained below.

### 720p formal pairs

`A→B` means baseline then optimized; `B→A` means optimized then baseline.

| Pair | Order | Baseline ms/frame | Optimized ms/frame | CPU B/A | RSS B/A |
| ---: | :---: | ---: | ---: | ---: | ---: |
| 1 | A→B | 0.913480 | 0.877538 | 0.9606537636 | 1.0076923077 |
| 2 | B→A | 0.933918 | 0.899318 | 0.9629517795 | 1.0092307692 |
| 3 | A→B | 0.821745 | 0.654254 | 0.7961764294 | 1.0115163148 |
| 4 | B→A | 0.911660 | 0.621971 | 0.6822400895 | 1.0130718954 |
| 5 | A→B | 0.816974 | 0.886447 | 1.0850369779 | 1.0034416826 |
| 6 | B→A | 0.799794 | 0.762222 | 0.9530229034 | 1.0065109154 |
| 7 | A→B | 0.492802 | 0.843944 | 1.7125417510 | 1.0091918805 |
| 8 | B→A | 0.906213 | 0.864717 | 0.9542094408 | 1.0092201306 |
| 9 | A→B | 0.815819 | 0.830305 | 1.0177563896 | 1.0107568191 |
| 10 | B→A | 0.898546 | 0.856102 | 0.9527636871 | 1.0100000000 |

### 4K formal pairs

| Pair | Order | Baseline ms/frame | Optimized ms/frame | CPU B/A | RSS B/A |
| ---: | :---: | ---: | ---: | ---: | ---: |
| 1 | A→B | 0.585940 | 0.598816 | 1.0219749462 | 1.0032467532 |
| 2 | B→A | 0.839396 | 0.722771 | 0.8610608104 | 1.0019977525 |
| 3 | A→B | 0.630788 | 0.560514 | 0.8885933150 | 1.0026217228 |
| 4 | B→A | 0.829480 | 0.871846 | 1.0510753725 | 1.0018714910 |
| 5 | A→B | 0.837513 | 0.663420 | 0.7921309878 | 1.0028735632 |
| 6 | B→A | 0.747897 | 0.786228 | 1.0512517098 | 1.0017471609 |
| 7 | A→B | 0.738552 | 0.891030 | 1.2064553342 | 1.0003745318 |
| 8 | B→A | 0.653799 | 0.783538 | 1.1984386639 | 1.0033741565 |
| 9 | A→B | 0.862436 | 0.883912 | 1.0249015579 | 1.0022500000 |
| 10 | B→A | 0.917368 | 0.856744 | 0.9339152881 | 1.0035008752 |

## Independent single-sample diagnostics

The four diagnostic runs are an intentionally separate population. They use
only optimized commit `60b73098a4aa8ad704dcd55a460280f1999fc2e2`, sampled clocks enabled, and the
enhanced benchmark SHA-256
`be33b7ae131595d082a2c1fc70d3d1c924f1dfae6f8d4379ca3a1d7fbc432c74`.
There is one sample per backend/resolution, so these values describe code-path
shape and counters; they are not part of the formal A/B and do not support a
performance comparison between backends.

| Backend | Resolution | CPU/frame | CPU/command | RSS | Published snapshots |
| --- | --- | ---: | ---: | ---: | ---: |
| Data-only | 720p | 2.105413 ms | 36.937 µs | 28.109 MiB | 1,324 |
| CPU-IOSurface | 720p | 0.866668 ms | 15.204 µs | 40.922 MiB | 1,317 |
| Data-only | 4K | 3.308401 ms | 58.042 µs | 56.125 MiB | 1,326 |
| CPU-IOSurface | 4K | 0.855222 ms | 15.003 µs | 125.219 MiB | 1,310 |

Selected CPU-IOSurface mean sampled spans are:

| Measured span | 720p | 4K |
| --- | ---: | ---: |
| Display message handling (outer span) | 6.287 µs | 6.211 µs |
| Display decode (nested) | 2.205 µs | 2.165 µs |
| SurfaceStore round-trip (nested) | 3.841 µs | 3.275 µs |
| Publisher submit round-trip | 0.811 µs | 0.734 µs |
| Bitmap validation (nested) | 0.135 µs | 0.128 µs |
| Bitmap mutation (nested) | 1.389 µs | 1.366 µs |
| Damage journal append (nested) | 0.378 µs | 0.369 µs |
| Snapshot checkout | 2.534 µs | 2.576 µs |
| Snapshot damage plan | 41.418 µs | 39.568 µs |
| Snapshot CPU copy | 64.539 µs | 66.007 µs |
| Snapshot finish | 6.550 µs | 6.325 µs |
| Frame emit | 3.315 µs | 3.180 µs |

Display message handling contains decode and the SurfaceStore round-trip;
SurfaceStore in turn contains validation, mutation, and damage work. Those rows
must not be added. The table reports individual spans and deliberately derives
no synthetic total. SurfaceStore and publisher values include actor queueing
plus execution, not isolated queue-wait time.

Within the measured snapshot phases, damage planning and CPU copy are the
largest individual spans. Their similar 720p/4K per-snapshot means are
consistent with this workload touching the same small rectangles rather than a
full frame on each publication; a single diagnostic sample cannot establish
their share of total process CPU.

The CPU-IOSurface damage/copy counters are internally consistent:

| Resolution | Rectangles before merge | After merge | Full-copy bytes | Partial-copy bytes | Total catch-up bytes |
| --- | ---: | ---: | ---: | ---: | ---: |
| 720p | 170,886 | 74,957 | 7.031 MiB | 228.745 MiB | 235.776 MiB |
| 4K | 170,885 | 74,558 | 63.281 MiB | 227.527 MiB | 290.808 MiB |

Each CPU-IOSurface run reports exactly two new-slot full uploads. Count, area,
explicit, surface-initialization, and history-gap full-damage reasons are all
zero, as are fallback, pool-exhaustion, GPU, compositor, and native-video
counters. The Data-only controls report 4,654.688 MiB and 41,955.469 MiB of
full-frame snapshot copying at 720p and 4K respectively, but those controls are
not the production GUI publication path.

## Implemented changes and interpretation

This PR implements the low-risk instrumentation and plumbing slice:

1. `ChannelSerialBarrier` is a synchronous `Mutex<State>` object, removing one
   per-message actor hop while preserving record/cancellation races.
2. `MessageFramer` parses mini/full headers directly from its backing `Data`,
   avoiding header `subdata`; message bodies remain independent `Data` values.
3. Opt-in sampled phase timing plus damage/copy counters expose the CPU
   publication path. Diagnostics disabled is the default and performs no clock
   reads.
4. Retired connection metrics are accumulated by value rather than retaining
   old connections/transports, including migration rollback handling.
5. The deterministic benchmark, provenance ledger, fail-fast RSS/path gates,
   and analyzer make this evidence reproducible and reject mixed samples.

Screening found and fixed a validation helper that temporarily retained a
second Surface/`Data` value across mutation, defeating copy-on-write uniqueness
and causing a large regression. The final helper returns scalar validation
state before mutation. That finding is useful for future ownership work, but it
is not part of the formal performance result.

The combined PR does not isolate the causal CPU contribution of the mutex and
header-parsing changes. Given the formal variance and confidence intervals, it
claims correctness, observability, and removal of those specific hop/allocation
sites—not a production CPU improvement.

## Not implemented and next work

The structural CPU-IOSurface work remains separate:

1. make publisher submission a synchronous coalescer and use one persistent
   publication timer;
2. batch CPU commands and write directly to a writable IOSurface under one
   lock/unlock per publication interval;
3. replace copied bitmap bodies with message-backing/range ownership after
   async lifetime rules are explicit;
4. reduce the remaining SurfaceStore actor/COW hot path;
5. evaluate tile/row damage, contiguous-copy fast paths, and SIMD kernels only
   after the publication architecture is measured.

The formal result covers neither `automatic` backend selection nor a production
GUI. It also excludes GLib, Metal rendering, AppKit presentation, real/direct
live SPICE sessions, scaled copy, full-frame content, native video, and
VideoToolbox. It cannot validate the earlier direct-live batch whose display
activity stopped late.

## Correctness validation

The final source passed the complete host-side Swift suite outside the Codex
sandbox with warnings treated as errors:

```sh
swift test --disable-sandbox -Xswiftc -warnings-as-errors
```

Result: 375 tests in 71 suites passed.

## Artifacts

- [all 44 attempts](Results/CPUHotPath_2026-08-04/attempts.jsonl)
- [four discarded warm-ups](Results/CPUHotPath_2026-08-04/warmups.jsonl)
- [720p formal samples](Results/CPUHotPath_2026-08-04/formal_720p.jsonl)
- [4K formal samples](Results/CPUHotPath_2026-08-04/formal_4k.jsonl)
- [independent diagnostic samples](Results/CPUHotPath_2026-08-04/diagnostics.jsonl)
- [host, toolchain, commit, and harness metadata](Results/CPUHotPath_2026-08-04/metadata.json)
- [bootstrap statistics and attempt audit](Results/CPUHotPath_2026-08-04/stats.json)
- [artifact SHA-256 manifest](Results/CPUHotPath_2026-08-04/SHA256SUMS)
- [provenance, gate, and statistics analyzer](analyze_cpu_hotpath.py)
