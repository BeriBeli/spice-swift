# MJPEG ready-batch optimization and real A/B, 2026-11-14

Bounded batching removes repeated candidate synchronization and publication
submissions for already-decoded native MJPEG fragments. In this real Linux Lite
A/B pair, client CPU fell from **85.55% to 71.95%** of one core: **13.60 percentage
points**, or **15.90% relative**. Synchronization attempts per accepted native
fragment fell **76.09%**, and mutation submission requests per accepted native
fragment fell **64.00%**. Both builds delivered all forty real marker inputs;
GPU errors remained zero.

This establishes a removable client cost and a CPU improvement in this pair.
It does not isolate the exact cause of the previous CPU increase or establish
general latency acceptance. Readback rate increased and approximate native
acceptance fell slightly. Retain this implementation as unreleased work and keep
server default `off`. The historical 1,007.6 ms stall remains unexplained.

The [machine-readable results](../Benchmarks/Session/RESULTS_MJPEG_BATCH_2026-11-14.json)
contain raw differences, intervals, source/build hashes and restoration evidence.
The [previous candidate-copy report](PERFORMANCE_MJPEG_COPY_2026-11-14.md) and
all four earlier evidence archives remain unchanged. The new evidence archive
is `spice-swift-mjpeg-batch-2026-11-14.zip`; its offline analyzer accepts an
explicit evidence directory and output path.

## CPU investigation and removed work

The previous incremental-copy path still checked out and synchronized a writable
candidate for each native fragment, submitted a separate composition command,
resumed the stream task and requested publication. Publication later coalesced
many requests, after their submission cost had already occurred.

Exploratory profiles show GPU submission, copy work, Swift task/workqueue
scheduling and JPEG decode. A ten-second Time Profiler capture of the earlier
full-copy build contains 7,315 ms of on-CPU sample weight. Inclusive samples
include approximately 728 ms in Metal queue submission, 604 ms in IOSurface
blitting and 782 ms in TurboJPEG decode. These stacks overlap; their inclusive
times must not be added as separate percentages. A separate ten-second
`sample` capture of the incremental-copy control also contains command encoding,
submission/completion and scheduling stacks. It includes waiting stacks and
cannot be compared numerically to Time Profiler on-CPU percentages. Neither
profile is part of the formal A/B CPU window, and neither cleanly attributes
the previous report's CPU increase.

The implementation therefore targets the demonstrated repetition:

- Each existing asynchronous MJPEG stream task can queue one decoded native
  draw and awaits its result before decoding another. Existing stream/decoder
  limits bound retained frames.
- One owned manager per Surface immediately drains the ready prefix, at most
  **eight** draws. There is no timer, additional batching delay or wait for a
  missing stream. Other ready draws can accumulate while GPU work is in flight.
- The Surface transaction validates each member, shares one candidate catch-up,
  encodes accepted draws into one composition command buffer and awaits one
  composition completion. All accepted members receive the same committed
  immutable revision. The channel requests its publication once.

The previous incremental catch-up remains. A broader batch can require larger
catch-up regions, but fewer transactions are submitted. Publication cadence,
presentation policy, slot budgets, codecs and server configuration are unchanged.
The change adds no locks, detached tasks or `@unchecked Sendable` declarations.

## Correctness and lifetime boundaries

Geometry, clipping, lifecycle, desktop-write barriers and overlapping video
sequence checks remain per member. Accepted sequences are staged in order while
validating a batch, so an older overlapping update cannot overwrite a newer
accepted update. Invalid/stale members reject individually before encoding.
Encoding or GPU failure aborts all accepted members; it publishes neither their
pixels nor their staged wire guards. Unknown, aborted or expired candidates
retain complete repair, and pending CPU damage survives later native catch-up.

Every encoder uses the same destination Metal texture, preserving tracked
resource dependencies between overlapping draws. Decoded frame leases, texture
bindings and destination ownership survive GPU completion. Published snapshots
are never modified in place. Stream cancellation resolves queued draws; active
managers remain owned until completion. Channel close drains those managers
before releasing decoders and Surfaces. Injected Data-backed and advanced-video
paths keep their existing scheduling behavior.

Regression coverage checks a batch with disjoint updates, clipped overlap and
an older stale member; its accepted members share one synchronization and
revision, with correct pixels and unchanged retained snapshots. Parameterized
failures cover an injected GPU failure and a later encoding failure after the
first draw has been encoded. Neither publishes pixels/guards, and a later older
sequence can recover fully. Real native JPEG stream tests verify destruction
and channel close drain active work.

All **755 SwiftSpice tests** passed with warnings-as-errors and all **755** passed
under AddressSanitizer. All **57 Maspice tests** passed. The existing
`PACKAGE=0 ./Scripts/build-app.sh` workflow built Release successfully; native
dependency closure and ad hoc signature checks passed. Native artifacts and C
shims did not change. Maspice's original release pin was restored while retaining
the local editable dependency. These are local checks; no remote CI or release
was run. No production edit, build, test or profiler ran during the formal A/B.

## Matched setup and actual intervals

Formal order was incremental-copy control A, then ready-batch candidate B, using
the same running QEMU process **141588** and one connected viewer at a time.
Reconnection resets decoder/server stream state. Both steady windows contain
zero additional stream-create messages. Earlier exploratory/profile observations
are explicitly excluded from the formal comparison.

Control executable SHA-256:
`365373eed1018633b4957588d6892c40ed0a0ee85683e61af98ebc27b7fd05f7`.
Candidate executable SHA-256:
`4f421dbbf507f616cc7ed0bf920429a33f25acd817e74c88e11841a1ac09ed53`.

Both used QEMU 11.1.2, SPICE package 0.16.0-4, explicit `streaming-video=all`,
four vCPUs, 6144 MiB, `virtio-vga,xres=1920,yres=1080`, `gtk,gl=off`, existing
compression/codec settings and the original `~/Downloads/linuxlite.vv`, with
CA and full certificate subject validation. QEMU, loaded SPICE library and
launcher hashes are recorded. The other VM and TLS relay remained running.

The same 750-byte guest fixture was independently verified with SHA-256
`f48393b4a9b7cced1cce29fc7af837901f762986f22c5a2d87002610c7e62e2b`.
It changes a 160×90 canvas scaled fullscreen, requests 30 FPS and stops after
5,400 callbacks, nominally 180 seconds. This request does not verify delivered
output FPS. Both runs included an explicit 30-second warmup wait and a bounded
60-second CPU acquisition. Tool/observation overhead made actual warmups before
the first Display sample **38.925 / 36.898 s**. Display end observations occurred
**140.583 / 125.949 s** after starting the fixture.

Display and CPU windows have different endpoints. Rates below use their own
recorded intervals. CPU uses each host's paired monotonic process counters,
including the recorded Mach timebase conversion; no cross-host clock subtraction
is used. CPU windows lie inside their respective Display windows. This is one
sequential A/B pair, without randomized repetitions or a fixed delivered rate.

## Results

| Metric | Incremental-copy A | Ready-batch B |
| --- | ---: | ---: |
| Display observation interval | 101.658 s | 89.051 s |
| MJPEG decoded fragments | 79,945 | 71,359 |
| Decoded fragments / observation second | 786.41 | 801.33 |
| Accepted native fragments | 78,085 | 68,856 |
| Accepted native / decoded | 97.67% | 96.49% |
| Decoded minus accepted native | 1,860 | 2,503 |
| Display received data | 21.51 Mbit/s | 22.29 Mbit/s |
| Copy synchronization attempts | 82,197 | 17,334 |
| Synchronization attempts / accepted native fragment | 1.0527 | 0.2517 |
| Mutation submission requests | 96,001 | 30,474 |
| Mutation submissions / accepted native fragment | 1.2294 | 0.4426 |
| Snapshot preparations / publication emits | 9,289 / 9,201 | 8,469 / 8,042 |
| Accounted canonical copy traffic | 1.110 GiB/s | 0.984 GiB/s |
| Copy wait total | 36.834 s | 15.537 s |
| Copy wait mean / counted synchronization | 0.448 ms | 0.896 ms |
| Copy wait / accepted native fragment | 0.472 ms | 0.226 ms |
| Metal commit count | 9,199 | 8,041 |
| Readbacks / pool exhaustion | 298 / 1,860 | 399 / 492 |
| Readbacks / observation second | 2.93 | 4.48 |
| GPU errors | 0 | 0 |
| Client CPU interval | 60.262 s | 60.252 s |
| Client CPU, one-core basis | 85.55% | 71.95% |
| QEMU CPU, one-core basis | 55.83% | 55.82% |

Client CPU fell **13.60 percentage points**, with decoded fragment rate **1.90%**
higher and QEMU CPU approximately unchanged. This supports the batching
direction under this workload; it does not prove a universal saving. CPU and
Display windows differ, so exact CPU-per-fragment cost is not inferred.

Per accepted native fragment, synchronization attempts fell **76.09%** and
mutation submission requests **64.00%**. Their per-second reductions were
**75.93% / 63.76%**. Copy traffic rate fell **11.35%**. Mean wait per counted
synchronization approximately doubled as each batch did more work; aggregate
copy wait per observation second fell **51.85%**, and wait per accepted native
fragment fell **52.17%**. These waits include GPU queue/completion and actor
resumption; accounted bytes are work counters, not hardware bandwidth utilization.

Counter granularity matters. Native video counts remain **accepted fragments**,
not distinct batch commits. Synchronization and mutation counters also include
non-video desktop work; their normalized ratios are not exact batch sizes.
Mutation submissions are requests before coalescing, distinct from publication
emits. Metal commits can present partial updates and do not measure complete
source-frame FPS. Pool exhaustion now counts one failed checkout per batch,
which can affect several fragments; its smaller count alone cannot establish a
proportional reduction in affected fragments.

Readbacks rose from **2.93 to 4.48/s**, and approximate native acceptance fell
**1.18 percentage points**. Retain both concerns. Every recorded decode used
IOSurface storage, with no decoder Data fallback, predecode late drop or
superseded-before-decode drop. The displayed CPU-fallback counter covers advanced
video, while decoder Data fallback describes storage; neither enumerates all
MJPEG composition fallbacks. The residual decoded-minus-native gap remains
unclassified. Memory endpoints do not establish a peak-memory improvement.

## Input, visual observations and timing limits

Both builds delivered **40/40** real Space presses, two batches of twenty with
100 ms holds, with screenshot counts 0, 20 and 40. Local queue p95 at the marker
end was **0.1 ms** for both; send p95 was **1.0 / 0.4 ms**, with zero send
failures. These separate checks establish input delivery, without per-key
input-to-presented or input-to-photon measurement.

Unaligned steady screenshots retain broad gradient phase boundaries. They do
not establish objective image quality, source-frame age or complete-frame atomicity.
Deterministic tests separately establish clip/order correctness and immutable
snapshot ownership.

Cumulative `currentDrawable` p95/max was **0.2/1.6 ms** for A and **0.2/1.9 ms**
for B. Revision-request-to-presented p95 was **32.6 / 33.0 ms**. There were no
drawable misses, presentation errors or CPU presentation fallbacks. The
historical one-second stall was neither reproduced nor explained.

Do not claim latency improvement from receive-to-ready timing: B reports one
representative member per submitted batch revision, while A submits individual
native fragments. The populations differ. All p95/max values are cumulative
session histograms, not window deltas. Receive idle-gap maxima include deliberate
pauses between actions; percentile/max subtraction is invalid.

## Decision, restoration and evidence handling

Keep the bounded batching change and its correctness coverage as unreleased
work. The next client target is readback/native fallback pressure under the
same workload. Broader resize, occlusion, display-cadence and hardware acceptance
remains pending. Do not promote server `all` or infer a general latency win.

Linux Lite was gracefully restarted to its original no-explicit-mode startup,
default `off`, PID **145601**. Original installed Maspice **0.6.1** remains
unchanged and is the only viewer, PID **92998**. It uses the original connection
file; the original marker is visibly fullscreen at **0**, with one browser tab
and the full-field fixture unloaded. Test viewers exited. The other VM, TLS
relay and launcher hash are preserved. No release was published.

During exploratory profiling, a Time Profiler TOC unexpectedly printed process
environment credentials into tool output. The user was informed and advised to
rotate the exposed credentials. The task-owned raw `.trace` was deleted;
environment nodes were removed from the saved TOC, and only the CPU table and
sanitized metadata were retained. The archive excludes raw traces, environment
payloads, connection-file contents and application binaries. Earlier tool output
has not been erased; local artifact cleanup does not revoke credentials.
