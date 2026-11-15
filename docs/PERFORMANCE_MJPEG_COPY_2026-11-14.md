# MJPEG candidate-copy optimization and real A/B/A, 2026-11-14

The bounded candidate catch-up implementation removes repeated full-Surface
copies while preserving transactional publication. In the real Linux Lite test,
accounted bytes per copy attempt fell **82.3%**, from **8,294,400** to an average
**1,469,794**. Average synchronization wait fell **19.4% / 31.0%** against the two
control windows. Native commits remained approximately **99%** of decoded
fragments, and both builds delivered all forty marker inputs.

This proves lower copy amplification. Overall performance acceptance remains
open: candidate client CPU was **81.8%** of one core, versus **70.9% / 74.3%** for
the controls, with higher pool exhaustion/readbacks and no established per-key
latency improvement. Keep the implementation as unreleased work and retain
server default `off`. The next target is the number and scheduling of fragment
submissions, with CPU attribution before further optimization. The historical
1,007.6 ms selection-to-commit stall remains unexplained.

The [machine-readable results](../Benchmarks/Session/RESULTS_MJPEG_COPY_2026-11-14.json)
retain raw counter differences, actual intervals, hashes, caveats and restoration
evidence. The preceding [region-ordering A/B/A](PERFORMANCE_MJPEG_REGIONS_LIVE_2026-11-14.md)
and its archives are unchanged.

## Change and ownership

The preceding corrected build synchronizes each partial native-video candidate
with a complete canonical Surface, even when its pool slot holds a known recent
revision. At 1920×1080 BGRA, each such copy moves 8,294,400 bytes. The new path
uses the existing three-commit damage history to copy only regions changed since
that candidate revision, encoding them in one blit command buffer. An already
current candidate needs no copy command. Unknown, aborted or expired candidates
still require a complete repair; the existing damage coverage policy can also
promote catch-up to a full copy.

Native commits now retain bounded damage history and record both their clipped
video destinations and pending CPU damage uploaded during composition. Including
the CPU damage prevents a later recycled candidate from losing a CPU fallback
update. Opaque canonical mutations continue resetting the history baseline.
Copy-byte diagnostics count the actual encoded rectangles.

The writable candidate remains separate from the published source. GPU work
completes before `finish`; retained snapshots keep their leases and immutable
pixels. Existing clip, overlapping wire-order, desktop-write, lifecycle and
failure checks remain. There is no new buffering interval, slot budget, lock,
detached task or in-place write to a published Surface. Nonempty synchronization
still incurs its command submission/completion wait, followed by composition.
This change does not combine separate video fragments into one composition.

## Local verification

Before changing production code, the native-strip regression test failed on the
old implementation: 32 small updates copied **32,768 bytes** on a 64×4 Surface.
The new implementation passes a bound below **8,192 bytes**, including first-use
initialization. It also checks the final strip pixels and retained old snapshots.
Holding the recent slots and releasing a candidate outside the history forces
the expected full repair, without modifying the held snapshots.

Additional checks cover two disjoint eight-byte-total region copies, invalid and
overflowing rectangles, empty catch-up without a command, aborted candidates
rejecting incremental reuse, full recovery after abort, and pending CPU video
damage surviving subsequent native candidate reuse.

All **752 SwiftSpice tests** passed normally and under **AddressSanitizer**, with
warnings-as-errors in the normal test build. All **57 Maspice tests** passed.
`PACKAGE=0 ./Scripts/build-app.sh` built the Release app; native dependency
closure and ad hoc signature verification passed. No native artifacts or C shims
changed. The local editable dependency was retained for testing and the original
SwiftSpice 0.4.5 release pin was restored in Maspice's lockfile. No production
edits, builds or test runs occurred during the live comparison.

## Controls and measurement

The order was corrected full-copy control A, region-copy candidate B, then the
same preserved control A again. The return window was added to check the CPU
increase observed in B. All three used the same running QEMU process, PID
**137859**, with explicit `streaming-video=all`; one viewer was connected at a
time. Reconnecting resets decoder/server stream state. All three steady windows
had zero additional stream-create messages.

The control executable SHA-256 is
`fb0b122f4c2eebd9d028a20de1b16f66ec53f020c38a19e66a18478b6ce0b420`;
candidate SHA-256 is
`365373eed1018633b4957588d6892c40ed0a0ee85683e61af98ebc27b7fd05f7`.
The control already contains the previous region-ordering correctness fix.

Fixed settings were QEMU 11.1.2, SPICE package 0.16.0-4, four vCPUs, 6144 MiB,
`virtio-vga,xres=1920,yres=1080`, `gtk,gl=off`, existing compression/codec options
and the original `~/Downloads/linuxlite.vv`, with CA and full subject validation.
The launcher, QEMU and loaded SPICE library hashes match the preceding evidence.
The other VM and TLS relay stayed running. No H.264 encoder, network shaping,
server software or installed-client change was introduced.

The same guest fixture was independently verified at 750 bytes and SHA-256
`f48393b4a9b7cced1cce29fc7af837901f762986f22c5a2d87002610c7e62e2b`.
It changes a 160×90 canvas scaled fullscreen, requests 30 FPS and stops after
5400 timer callbacks, nominally 180 seconds. The measured output cadence is not
established by that timer request. Warmup before the first Display observation
was **31.867 / 14.038 / 29.487 seconds**; warmup length was not identical.

Visible Diagnostics supplied periodically sampled, best-effort Display counters.
CPU uses paired process counters and each host's own monotonic interval, with
the recorded Mach timebase conversion on macOS. CPU and Display windows have
different endpoints; each rate uses its own interval. This is sequential A/B/A
with one candidate window, without randomized repetitions or a fixed delivered
fragment/presentation rate.

## Actual results

| Metric | Full-copy A | Region-copy B | Return to A |
| --- | ---: | ---: | ---: |
| Display observation interval | 82.258 s | 85.883 s | 89.059 s |
| MJPEG decoded fragments | 66,762 | 64,884 | 61,131 |
| Native Surface commits | 66,057 | 64,060 | 60,626 |
| Native commits / decoded | 98.94% | 98.73% | 99.17% |
| Decoded minus native commits | 705 | 824 | 505 |
| Display received data | 22.24 Mbit/s | 20.73 Mbit/s | 18.76 Mbit/s |
| Accounted canonical GPU copies | 6.50 GiB/s | 1.08 GiB/s | 5.59 GiB/s |
| Mean bytes per counted copy | 8,294,400 | 1,469,794 | 8,294,400 |
| Copy synchronization attempts | 69,196 | 67,519 | 64,445 |
| Copy wait total | 41.58 s | 32.72 s | 45.25 s |
| Copy wait mean in window | 0.601 ms | 0.485 ms | 0.702 ms |
| Metal commit count | 6,728 | 7,724 | 7,138 |
| Readbacks / pool exhaustion | 100 / 689 | 137 / 824 | 80 / 505 |
| GPU errors | 0 | 0 | 0 |
| Client CPU, one-core basis | 70.95% | 81.81% | 74.33% |
| Client CPU observation interval | 56.784 s | 64.909 s | 72.792 s |
| QEMU CPU, one-core basis | 55.91% | 54.94% | 53.80% |

Bytes per attempt fell 82.3% against either control. Copy traffic per observation
second fell 83.4% / 80.7%, with different actual fragment rates. Copy waits include
GPU queue/completion and actor resumption; the bytes represent accounted copy
work, rather than measured hardware bandwidth utilization. The copy operation
cost is lower, but the per-fragment submission/completion pattern remains.

CPU rose by 10.87 / 7.49 percentage points against the two controls. Returning to
A did not reproduce B's CPU level. However, automatic server adaptation,
different warmups, fragment rates and Metal commit cadence prevent clean CPU
attribution from this single B window. More Metal commits occurred per observation
second in B; these can present partial updates and are not complete-frame FPS.
The result establishes neither a CPU saving nor the exact cause of its increase.
Higher readback/pool pressure is retained as a concern. Performance acceptance
must not treat the byte reduction as sufficient on its own.

Every recorded decode used IOSurface storage, with zero decoder Data fallbacks,
predecode clock drops and superseded-before-decode drops. Native/decoded is an
approximate ratio across actor samples, not per-fragment rejection attribution.
Its CPU-fallback row covers advanced video; decoder Data fallback describes
storage. Neither proves zero MJPEG composition fallbacks. The uncaptured native
fallback counter leaves the residual gap unclassified.

## Output, input and limits

The saved steady screenshots for all three windows show one or a few broad
gradient phase boundaries. They do not establish an additional narrow-strip or
snapshot-corruption pattern from candidate catch-up. Phases are unaligned and
there is no pixel reference, objective quality score or atomic full-frame claim.
Deterministic tests separately verify preserved pixels and snapshot ownership.

The separate marker checks delivered **40/40** real Space presses for A and
**40/40** for B, in two batches of twenty with 100 ms holds. Screenshots confirm
counts 0, 20 and 40. Both had local queue p95 **0.1 ms**, local send p95 **0.5 ms**
and zero send failures. These are delivery and local aggregate timing checks,
separate from the full-field animation, without per-key input-to-presented or
input-to-photon measurements.

Cumulative `currentDrawable` p95/max was **0.2/6.9 ms**, **0.2/1.9 ms** and
**0.2/1.6 ms**. Revision-request-to-presented p95 was **33.0 / 32.7 / 32.7 ms**.
The histograms include warmup and prior session activity; percentiles and maxima
are not subtracted. Receive idle gaps include deliberate pauses. None reproduces
or explains the historical 1,007.6 ms selection-to-commit stall.

## Decision and restoration

Retain the safe region-copy implementation and its correctness coverage as
unreleased work. Do not promote `streaming-video=all` or claim a general latency,
CPU or smoothness win from this result. Next capture CPU attribution under a
matched delivered workload and reduce repeated fragment synchronization and
publication work within a bounded scheduling policy. Preserve clipping, wire
order, lifecycle validation, immutable snapshots and full recovery of uncertain
candidates. Broader input, resize, occlusion, display-cadence and hardware
acceptance remains pending.

Linux Lite was gracefully restarted with its original no-explicit-mode startup,
default `off`, PID **139276**. Installed Maspice **0.6.1** was preserved and
restored as the only viewer, PID **86425**, using the original connection file.
The original marker is visually confirmed fullscreen at **0**, with only its
browser tab open; the full-field page is unloaded. Test viewers exited, the
other VM and TLS relay stayed running, and the server launcher hash is unchanged.
No release was published.
