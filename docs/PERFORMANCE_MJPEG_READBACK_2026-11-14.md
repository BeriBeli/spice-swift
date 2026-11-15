# Native candidate pressure and real A/B, 2026-11-14

A native batch previously fell back immediately when consumer leases occupied
the writable candidates. One failed checkout rejected every accepted member;
the stream tasks then performed separate CPU scaled-copy fallbacks. Native
commits interleaved with those CPU writes can invalidate the Data mirror again,
causing repeated canonical readbacks. This explains why counting failed
checkouts understated affected fragments after batching.

The fix waits for a matching non-source consumer lease to release, with a
**16 ms timeout deadline**, before retrying native checkout. In this real A/B
pair, readbacks fell **1.96 → 0.91/s**, and approximate native acceptance rose
**98.26% → 99.22%**. Both builds delivered all forty real marker inputs and
recorded zero GPU errors. Remaining capacity/deadline failures retain the
bounded CPU fallback. Vertical color phase boundaries remain visible.

The [machine-readable record](../Benchmarks/Session/RESULTS_MJPEG_READBACK_2026-11-14.json)
contains differences, intervals, source/build hashes and restoration evidence.
The new archive is `spice-swift-mjpeg-readback-2026-11-14.zip`; its analyzer takes
explicit input/output paths. The preceding [ready-batch report](PERFORMANCE_MJPEG_BATCH_2026-11-14.md)
and five earlier archives are unchanged.

## Resource ownership and tradeoff

Fallible native composition still requires a distinct candidate; canonical or
externally leased pixels cannot be overwritten. The existing three-slot ring
and process-wide allocation budget are unchanged. After a failed checkout, the
pool checks under its existing mutex whether a matching non-source slot is
temporarily leased. Impossible capacity/budget configurations with no such
candidate return immediately. Registration checks for a newly available slot
under the same mutex, avoiding a lost wakeup between checkout and registration.

An `AsyncStream` signal wakes on lease release; a structured task group races
that signal against the deadline. Cancellation, retirement and timeout remove
waiters. Signals finish outside the pool mutex, including synchronous termination
cleanup. No new mutex, detached task, unchecked-Sendable declaration or extra
Surface slot was added. Existing Surface operation ownership spans the bounded
asynchronous admission wait; no pool mutex spans `await`. Lifecycle and task
cancellation are rechecked before checkout and mutation. Candidate rollback,
wire ordering, clipping and immutable snapshot rules remain.

The deadline can add admission latency under pressure. It is a timer deadline,
not a hard real-time guarantee on scheduler resumption. Failed recovery still
returns the existing typed frame fallback, without disabling the stream's Metal
generation. The new aggregate counters count **batch recovery attempts** and
successful subsequent checkouts; an attempt can return immediately for permanent
capacity. Native fallback continues counting affected **fragments**. Both A/B
builds expose these same counters; the control leaves recovery counters at zero.

## Verification and controls

Focused resource tests verify consumer release, cancellation, retirement and
deadline cleanup. A permanent one-slot configuration rejects all four batch
members with one checkout failure, preserves the retained GPU snapshot, and
allows their CPU updates with one shared Data-mirror materialization. Existing
clipped wire-order, failed-encoding/GPU rollback, full candidate repair and stream
destruction/close tests remain passing.

All **757 SwiftSpice tests** passed normally with warnings-as-errors and under
AddressSanitizer. All **57 Maspice tests** passed. Both Release builds used the
existing `PACKAGE=0 ./Scripts/build-app.sh`; closure and signature checks passed.
No native artifact/C shim changed. The original release pin was restored while
retaining the local editable dependency. No remote CI or release was performed.

The control is the previous ready-batch implementation plus additive diagnostics,
SHA-256 `63af31f436797c3f32f0c744f428bf30a7a11e094bed9df58d72a35196c4b299`.
The candidate is
`a96a051b6903d582af31632f220ad299570474870acbe66247561f80aefecbc4`.
Only B changes native resource admission behavior. No source edit, build, test
or profiler ran during the formal windows.

Both used running QEMU PID **151302**, explicit `streaming-video=all`, QEMU
11.1.2, SPICE 0.16.0-4, four vCPUs, 6144 MiB, virtio-vga 1920×1080 and
`gtk,gl=off`, with existing compression options. One viewer used the original
`~/Downloads/linuxlite.vv`, CA and full certificate subject validation at a time.
The launcher, QEMU and loaded SPICE hashes are retained in the JSON record.
The other VM and TLS relay stayed running.

The same independently verified 750-byte fullfield fixture has SHA-256
`f48393b4a9b7cced1cce29fc7af837901f762986f22c5a2d87002610c7e62e2b`.
It requests 30 FPS from a 160×90 fullscreen-scaled canvas and stops at 5,400
callbacks, nominally 180 seconds. Requested cadence is not verified output FPS.
Both runs used a 30-second explicit warmup wait and a bounded 60-second CPU
acquisition. Observation overhead made actual warmups **39.327 / 43.451 s**;
end observations were **125.237 / 127.936 s** after starting the fixture.

After candidate reconnect/navigation, the canvas went black before any native
MJPEG or pool-wait activity. Clicking/focusing the guest restored the marker.
This preflight is saved separately, with cause unresolved, and excluded from
the formal window. No code edit or VM restart separated A and B.

## Measured results

| Metric | Immediate fallback A | Lease recovery B |
| --- | ---: | ---: |
| Display interval | 85.910 s | 84.485 s |
| Decoded MJPEG fragments | 65,629 | 58,020 |
| Decoded fragments / second | 763.93 | 686.75 |
| Accepted native fragments | 64,487 | 57,565 |
| Native / decoded | 98.26% | 99.22% |
| Native fallback fragments | 1,125 | 465 |
| Pool checkout failures | 191 | 77 |
| Recovery attempts / recovered | 0 / 0 | 168 / 91 |
| CPU materializations | 168 | 77 |
| Materializations / second | 1.956 | 0.911 |
| Canonical copy synchronization attempts | 16,492 | 14,620 |
| Accounted canonical copy traffic | 0.998 GiB/s | 0.903 GiB/s |
| GPU errors | 0 | 0 |
| Client CPU interval | 60.260 s | 60.232 s |
| Client CPU, one-core basis | 64.59% | 56.69% |
| QEMU CPU, one-core basis | 55.22% | 53.60% |

Readback rate fell **53.39%**; readbacks per decoded fragment fell **48.16%**.
Native fallback per decoded fragment fell **53.25%**, and native acceptance
rose **0.96 percentage points**. Of B's 168 recovery attempts, 91 obtained a
candidate; the remaining 77 correspond to final checkout failures. A failed
checkout affected approximately **5.89 / 6.04 fragments** in A/B. This validates
transient lease pressure and batch fanout as a material source of fallback.
The exact remaining capacity/timeout/allocator split is not captured.

Client CPU was 7.90 percentage points lower, but delivered fragment rate was
**10.10% lower** too, with adaptive server output. This single pair does not
isolate the CPU saving attributable to admission recovery. CPU and best-effort
Display samples have different endpoints; each uses its own actual interval
and each host's own monotonic counters. Exact CPU-per-fragment cost is not
inferred. Endpoint native/fallback totals have small actor-sampling residuals;
they are not exact per-fragment rejection attribution.

Both builds delivered **40/40** Space presses in two batches of twenty, with
100 ms holds and visible counts 0, 20, 40. Local queue p95 was **0.1 / 1.0 ms**,
send p95 **0.5 / 0.5 ms**, with zero send failures. These are separate input
delivery checks, without per-key presented or input-to-photon measurements.

Cumulative receive-to-ready p95 remained **12 ms**, while max was **24.0 / 35.4
ms**; admission waiting has a latency tradeoff. Revision-request-to-presented
p95 remained **33 ms**. `currentDrawable` max was **9.6 / 8.4 ms**. Histograms
are cumulative and no percentile/max subtraction is performed. Receive idle
gaps include the preflight and pauses. No one-second-stall root cause or general
latency improvement is established.

## Vertical color boundaries

The saved screenshots still show vertical color phase boundaries in both builds;
resource admission did not eliminate them. SPICE stream creation describes a
destination rectangle, and stream data carries its stream ID and multimedia
timestamp. Its documented stream messages do not provide a cross-stream
whole-desktop completion fence. See the primary [SPICE protocol, video streaming
commands](https://www.spice-space.org/spice-protocol.html).

Locally, `DisplayChannel` maintains timestamps per stream, while ready batches
are formed from arrival/decode readiness rather than a shared timestamp. The
observed bands are consistent with neighboring regions showing different color
phases, but these unaligned screenshots do not isolate server capture from client
publication or establish exact source-frame age. A later investigation should
measure region timestamps/source phase and publication cohorts before adding
bounded frame-coherent presentation. Waiting indefinitely for all streams would
stall static, dropped or retired regions. No objective quality score, complete
source-frame FPS or vertical-line fix is claimed here.

## Decision and restoration

Retain the bounded recovery change as unreleased work. It substantially reduces
one demonstrated readback/fallback source while preserving the capacity fallback.
Remaining pressure, the admission-latency tradeoff, vertical boundaries and
broader resize/occlusion/cadence/hardware acceptance remain open. Keep server
default `off`; do not promote `all` from this pair.

Linux Lite was gracefully restored to its original no-explicit-mode startup,
default `off`, PID **151834**. Installed Maspice **0.6.1** is unchanged and was
restored as the only viewer, PID **99054**, using the original connection file.
The marker is visibly fullscreen at **0**, with one browser tab and the fullfield
fixture unloaded. Test viewers exited; CentOS PID **26919**, TLS relay **3368**
and the launcher hash are unchanged. This restoration is the endpoint of this
dated experiment; separately requested CocoaSpice/Spicy comparisons follow it.
