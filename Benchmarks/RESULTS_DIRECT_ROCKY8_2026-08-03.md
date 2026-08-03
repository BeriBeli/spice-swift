# Direct CPU-IOSurface versus Metal Rocky results

Test date: 2026-08-03 (Asia/Singapore)

Tested renderer head: `bb3b1768f1cd885ed45e120a55ffa23afc0d9d2d`

## Outcome

The direct live comparison was run. Both 1280x720 and 3840x2160 collected all
ten alternating 30-second `cpu-iosurface`/`metal` pairs, including samples after
the first integrity failure. Neither complete batch is valid performance
evidence: client display activity became incomplete after sustained use of the
persistent fixture, and the analyzer correctly rejected the retained
`integrity-failures.tsv` files.

The first contiguous activity-valid prefixes contain five pairs at 720p and six
pairs at 4K. They are reproducible diagnostics, not formal ten-pair results, and
both fail the performance analyzer. Metal used 1.731x and 1.754x as much host
CPU per published frame at 720p and 4K respectively. The 4K Metal RSS ratio was
1.341x. This run therefore makes no Metal-benefit, non-inferiority, or
production-default claim.

Renderer evidence itself was clean. Every formal Metal sample selected
revisioned IOSurface backing, submitted Metal commands, and recorded zero
supported CPU opcode executions, dedicated Metal-to-CPU fallbacks, CPU
materializations, scaled copies, GPU errors, and pool exhaustions. The failure
is an activity/performance failure, not a hidden CPU fallback or Metal
lifecycle failure.

## Test contract

- Host: MacBook Pro `Mac16,8`, Apple M4 Pro, 24 GB RAM, arm64, macOS 26.6
  (25G72), Xcode 26.6 (17F113), Swift 6.3.3.
- Client: arm64 Release `spice-probe` from the tested renderer head.
- Peer: isolated Rocky 9.8 QEMU/SPICE fixtures with the deterministic Alpine
  xterm workload, connected one client at a time through a loopback SSH tunnel.
- Codec: MJPEG. The workload emitted bitmap-copy commands and no native-video,
  VideoToolbox, or scaled-copy activity.
- Variants: CPU 2D and experimental Metal 2D, both with required revisioned
  IOSurface backing.
- Shape: ten alternating pairs at each resolution, 30 seconds per sample, with
  a deterministic reset before every sample.
- Identity gates: one boot epoch, codec, resolution, duration, reset source,
  and exact `width * height * 4` frame footprint across each complete batch.
- Activity gates: successful process/hook/boot probes, at least 80% active-span
  coverage, at least 8 of 10 active buckets, and a final frame no more than one
  second before observation end.
- Performance gates: paired bootstrap confidence intervals for fps,
  ready-frame latency, p95 frame interval, CPU per published frame, and RSS.
  Higher is better only for fps; the applicable upper limits are 1.10 for
  latency and CPU/frame and 1.15 for RSS.
- Guest gate: the independent generator telemetry must remain on the sample's
  boot epoch, generation, and PID; advance monotonically; and span at least 80%
  of the observation window.

`SWIFTSPICE_BENCH_CONTINUE_ON_FAILURE=1` was used to retain every requested
sample. It did not waive a gate. All Swift builds, Metal execution, and the
complete Swift test suite ran on the macOS host outside the filesystem sandbox.

### Fixture provenance

The two isolated fixture IDs were
`direct-bb3b176-20260803-v1-720` and
`direct-bb3b176-20260803-v1-4k`. Their artifact hashes are retained in every
result set's `fixture-manifest.json`:

| Artifact | 720p SHA-256 | 4K SHA-256 |
| --- | --- | --- |
| Guest kernel | `8da852cbf2e9cc6974f52ebd37c040b59244c66cf5220c8ac9d1c64c90e8d753` | same |
| Guest initramfs | `0300a51af4472cb378c81013f6c3ad33a288c928ee249460850b734a762e4e34` | `50606c721194abe858935eba8e603bb060c8aa9e8b0a43476eeadb098a8852a2` |
| Package database | `4d989e2a2689214dd90661ae79a14f8c087420c3447945f215f9eeff25ca06e1` | same |

The 720p initramfs was rebuilt from the tested guest source. A second package
download stalled while building 4K, so the completed identical 720p rootfs was
copied and only the verified 3840x2160 guest/QEMU configuration was overlaid
before repacking. Runtime status, Xorg, QEMU configuration, and every 4K sample's
`33,177,600 * frames` footprint independently confirmed 3840x2160. Declaring
`SWIFTSPICE_BENCH_RESOLUTION` alone does not resize the guest.

## Formal evidence disposition

| Resolution | Samples collected | Activity-valid samples | Contiguous valid pairs | First activity failure | Formal result |
| --- | ---: | ---: | ---: | --- | --- |
| 1280x720 | 20/20 | 11/20 | 1-5 | Pair 6 `cpu-iosurface` | **INVALID** (9 failures) |
| 3840x2160 | 20/20 | 12/20 | 1-6 | Pair 7 `cpu-iosurface` | **INVALID** (8 failures) |

Every process, after-hook, and end-boot probe exited zero. Each resolution used
one real boot epoch for the complete batch, retained MJPEG throughout, and
reported the exact expected frame footprint. Invalidity comes solely from
client activity coverage; renderer purity and sample identity do not rescue an
incomplete batch.

At 720p the first rejected sample still published 663 frames, but covered only
5 of 10 buckets over 13.345 seconds and ended 18.049 seconds before the window.
Pairs 7-10 then published one frame per renderer. At 4K, pair 7
`cpu-iosurface` published 248 frames over 2 buckets and 5.114 seconds, ending
26.235 seconds before the window; that pair's Metal sample and pairs 8-10 then
published one frame each.

The pair JSON, metadata, time samples, and corresponding remote-round evidence
in the five- and six-pair diagnostic prefixes are byte-identical copies from
the formal directories before the first incomplete pair. The derived
directories also contain their own manifests and analyzer outputs. They were
not selected by performance outcome and must not be combined with later
samples or reported as a formal batch.

## Activity-valid prefix diagnostics

Ratios are paired `metal / cpu-iosurface` bootstrap estimates with 95%
confidence intervals. Higher is better only for fps.

| Resolution | fps | Ready-frame | p95 interval | CPU/frame | RSS | Overall |
| --- | --- | --- | --- | --- | --- | --- |
| 720p (5 pairs) | 1.037491 [1.024390, 1.041953] PASS | **0.967597 [0.806556, 1.266334] FAIL** | 0.982990 [0.970242, 0.996054] PASS | **1.730965 [1.517812, 1.772704] FAIL** | 1.120592 [1.110703, 1.126371] PASS | **FAIL** |
| 4K (6 pairs) | 1.114127 [1.087453, 1.124723] PASS | 1.032517 [0.815094, 1.067716] PASS | 1.023784 [1.008347, 1.051762] PASS | **1.754194 [1.738703, 1.775017] FAIL** | **1.340859 [1.337367, 1.343431] FAIL** | **FAIL** |

The 720p ready-frame point estimate is below one, but its confidence interval
crosses the 1.10 ceiling. Passing fps or latency metrics does not override the
CPU/RSS failures or the invalid complete batch.

### Absolute medians

| Variant | fps | Frames / 30 s | Ready-frame | p95 interval | CPU/frame | Maximum RSS |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 720p CPU-IOSurface | 48.900 | 1,467 | 231.665 ms | 24.455 ms | 2.047 ms | 80.203 MiB |
| 720p Metal | 50.633 | 1,519 | 221.176 ms | 24.013 ms | 3.601 ms | 89.828 MiB |
| 4K CPU-IOSurface | 47.900 | 1,437 | 284.602 ms | 28.522 ms | 4.082 ms | 192.742 MiB |
| 4K Metal | 53.467 | 1,604 | 263.969 ms | 29.212 ms | 7.192 ms | 258.375 MiB |

These marginal medians are descriptive. Dividing them does not reproduce the
paired ratio or its confidence interval and must not be used as the gate.

### Five-second smoke checks

The one-pair five-second checks at both resolutions passed all integrity and
guest-telemetry gates. They still failed CPU/frame: the Metal/CPU-IOSurface
ratio was 1.422 at 720p and 1.613 at 4K; the 4K smoke also failed RSS at 1.341.
Short smoke success therefore did not establish full-duration fixture health or
performance acceptance.

## Guest telemetry localization

The new telemetry analyzer passed all six retained result sets. In the formal
720p batch it validated 20 samples and 358 records, with at least 17 records and
31.67 seconds of coverage per sample. At 4K it validated 20 samples and 373
records, with at least 18 records and 33.08 seconds of coverage per sample.
Both formal batches advanced exactly from generation 3 through 22 on one
generator PID, used non-overlapping uptime windows, and had a maximum heartbeat
gap of 2.10 seconds.

Most importantly, the generator's frame ID and monotonic uptime continued to
advance for every late sample whose client published-frame activity stopped.
Each selected sample remained on one generation, PID, and boot epoch, and the
server round logs retained the reset marker and subsequent heartbeats. Both
renderer variants failed after the boundary. This rules out a stopped guest
generator as the explanation for these direct-run failures and makes a
Metal-specific renderer stall unlikely.

It does not prove the exact downstream component. The heartbeat is emitted
after xterm finishes writing a terminal frame, but it does not count X11
Present/Damage. The remaining boundary includes xterm-to-Xorg presentation,
Xorg/QXL, spice-server, transport, and client receipt/publication. The similar
onset around fixture generations 14-15 suggests degradation in persistent
fixture state, but that is an inference rather than a confirmed root cause.

## Renderer and data-movement analysis

Median counters for the activity-valid Metal prefixes were:

| Counter | 720p Metal | 4K Metal |
| --- | ---: | ---: |
| Published frames | 1,519 | 1,604 |
| Metal command buffers | 1,519 | 1,605 |
| Metal commands (all bitmap copy) | 86,413 | 91,936 |
| Commands / command buffer | 57.004 | 57.168 |
| Initial batch-seed CPU copy | 3,686,400 B | 33,177,600 B |
| Batch-seed GPU copy | 5,599,641,600 B | 53,250,048,000 B |
| Snapshot catch-up CPU copy | 2,433,024,000 B | 32,497,459,200 B |
| Shared upload bytes | 273,781,504 B | 319,025,536 B |
| Upload-buffer allocations | 193 | 172 |
| Upload-buffer reuses | 86,275 | 91,815.5 |
| Metal draw-batch GPU time | 656.175 ms | 766.496 ms |
| Median per-sample draw-batch GPU time / command buffer | 0.432 ms | 0.475 ms |

The GPU seed counter is exactly one full-surface clone per command buffer:
`3,686,400 * 1,519 = 5,599,641,600` bytes at 720p and
`33,177,600 * 1,605 = 53,250,048,000` bytes at 4K. Command-buffer count tracks
published-frame count because snapshot publication flushes the pending batch;
each subsequent batch clones the full canonical IOSurface before applying about
57 small bitmap updates.

Snapshot catch-up grows from 2.43 GB to 32.50 GB while explicit upload traffic
only grows from 273.78 MB to 319.03 MB. Upload-buffer allocation fractions are
about 0.223% and 0.187%, so persistent-buffer reuse already exceeds 99.7%.
Allocation itself is not the leading measured problem, although per-opcode
Data-to-shared-buffer copying, encoding, submission, and waiting can still
contribute to the 73-75% host CPU/frame regression.

`metal_2d_gpu_time_ns` covers only the `SpiceMetal2DBatch` command buffer. It
excludes the separate full-surface revision seed blit, CPU snapshot catch-up,
upload copies, encoding/waits, and presentation. The median per-sample
0.432/0.475 ms values are not total GPU time or utilization and do not justify
prioritizing shader tuning over the unmeasured seed/catch-up/publication paths.

### RSS and revision scope

CPU-IOSurface retained one revisioned frame at the observation boundary; Metal
retained two. Median Metal-minus-CPU RSS was 10,092,544 B (9.625 MiB) at 720p
and 68,820,992 B (65.633 MiB) at 4K. One additional 4K IOSurface accounts for
33,177,600 B (31.641 MiB), making the revision ring and other Metal resources
plausible contributors to the 4K RSS failure. Device current-allocation,
IOSurface, and RSS counters can overlap and must not be added together.

## Code-analysis conclusion

The direct evidence changes the optimization order but does not justify default
enablement:

1. Remove or reduce the full-surface revision clone performed for nearly every
   published frame, while preserving batch rollback and stale-revision safety.
2. Reduce snapshot catch-up with dirty-rectangle or safe in-place generation
   work, especially at 4K.
3. Measure and reduce per-opcode upload/copy/encode/wait overhead. The persistent
   upload pool is already reusing more than 99.7% of requests, so increasing
   pool allocation alone is unlikely to solve the CPU regression.
4. Evaluate lower commit frequency only with a separate visible-latency gate;
   the current 16 ms publication boundary is an intentional responsiveness
   policy.
5. Defer shader micro-optimization until total seed/catch-up/encoding GPU and
   CPU time is measured.

Before another formal run, replace or repair the downstream persistent
xterm/Xorg fixture path, add X11 Present/Damage telemetry, and require a
full-duration 20/20 activity-valid preflight at both resolutions. Keep
`automatic` on CPU and retain `cpu-iosurface` as the production fallback and
matched-backing reference.

## Retained evidence and cleanup

The durable sanitized archive is
[`swiftspice-pr4-bb3b176-direct-renderer-results.tar.gz`](Results/2026-08-03/swiftspice-pr4-bb3b176-direct-renderer-results.tar.gz),
with its [checksum file](Results/2026-08-03/swiftspice-pr4-bb3b176-direct-renderer-results.tar.gz.sha256).
Its verified SHA-256 is
`e4af602279fb51089c46333c82f4762b9cb7639690d27c52cb6dee4f82903edb`
(90,949 bytes).

The archive contains both formal batches, both diagnostic prefixes, and both
five-second smoke sets; every client JSON/metadata/time sample; all exact
server/configuration/version/guest-telemetry round evidence; fixture manifests;
both analyzer outputs and exit codes; the exact tested runner/analyzer; the
collection-time hook and boot-epoch scripts; a manifest; and per-file SHA-256
checksums. The outer checksum and all 502 checksummed payload files were
verified, and a second full build reproduced the archive byte for byte. A
sensitive-field scan found no password, ticket, token, authorization,
credential, API key, or private-key field.

The two formal renderer-analyzer outputs fail because the activity integrity
files are retained. Both diagnostic prefixes and both smokes also exit nonzero
on performance gates. All six independent guest-telemetry analyses exit zero.
The remote QEMU endpoints were stopped, their temporary ticket files were
removed, and the local SSH tunnel was closed after collection.
