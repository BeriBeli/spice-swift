# Live MJPEG region-ordering A/B/A, 2026-11-14

Keep the region-ordering correction. On the actual Linux Lite session, native
Surface commits rose from **66.2% / 69.0%** of decoded fragments in the two
control windows to **99.4%** in the corrected window. Narrow vertical phase
strips substantially diminished in the saved observations and reappeared when
returning to the control executable. Broader phase boundaries remain.

This is a correctness improvement, with a measured cost: accounted canonical
GPU-copy traffic increased from **4.15 / 4.25 GiB/s** to **8.16 GiB/s**. Every
counted candidate copy still moves **8,294,400 bytes**, one complete 1920×1080
BGRA Surface. Keep server default `off` while reducing that repeated copy and
synchronization work. No end-to-end input-latency or complete-frame FPS gain is
established, and the historical 1,007.6 ms stall remains unexplained.

The [machine-readable results](../Benchmarks/Session/RESULTS_MJPEG_REGIONS_LIVE_2026-11-14.json)
retain counter differences, actual intervals, build hashes, limits and restoration
evidence. The [local correction record](PERFORMANCE_MJPEG_REGIONS_2026-11-14.md)
contains the deterministic reproduction and safety tests. Earlier archives and
the [off/all/filter comparison](PERFORMANCE_MJPEG_AB_2026-11-14.md) are unchanged.

## Controls and method

The test order was control A, corrected B, then control A again. The last window
checks whether the result follows the executable after the guest has warmed up.
All three used the same running QEMU process, PID 88854, with explicit
`streaming-video=all`; only the viewer was reconnected between windows.

Fixed settings were QEMU 11.1.2, SPICE package 0.16.0-4, four vCPUs, 6144 MiB,
`virtio-vga,xres=1920,yres=1080`, `gtk,gl=off`, existing automatic compression,
and the original `~/Downloads/linuxlite.vv` with its CA and full subject
validation. QEMU and the mapped SPICE library hashes match the prior record.
The other VM and TLS relay remained running. No traffic shaper, second viewer,
server software update or H.264 encoder change was introduced.

The preserved control executable SHA-256 is
`4f41f9f2467c59faf2fe43895f336cc3dd4b06933efbb6357dd0145390fe6f0f`;
the corrected Release executable is
`fb0b122f4c2eebd9d028a20de1b16f66ec53f020c38a19e66a18478b6ce0b420`.
The production and test source hashes still match the completed local validation.
No production edits or builds occurred during the live comparison.

All windows used the existing 750-byte full-field gradient fixture, independently
SHA-256 verified in the guest. It changes a 160×90 canvas scaled fullscreen,
requests 30 FPS and stops after 5400 timer callbacks, nominally 180 seconds.
Requested timer cadence is not verified output FPS. Each observation followed
21–32 seconds of warmup; all steady windows had **zero new stream-create messages**.

Display counters come from visible Maspice Diagnostics. CPU uses paired process
counters and each host's own monotonic interval. Their actual endpoints differ,
so each rate uses its own interval. These are sequential observations, with one
corrected-build window, rather than a randomized statistical benchmark.

## Actual results

| Metric | Control A | Corrected B | Return to control A |
| --- | ---: | ---: | ---: |
| Display observation interval | 65.192 s | 74.865 s | 69.655 s |
| MJPEG decoded fragments | 49,627 | 76,168 | 52,011 |
| Native Surface commits | 32,861 | 75,742 | 35,904 |
| Native commits / decoded | 66.22% | 99.44% | 69.03% |
| Decoded minus native commits | 16,766 | 426 | 16,107 |
| Display received data | 21.00 Mbit/s | 27.85 Mbit/s | 20.51 Mbit/s |
| Client CPU, one-core basis | 69.19% | 70.03% | 70.62% |
| QEMU CPU, one-core basis | 54.66% | 59.26% | 54.53% |
| Accounted canonical GPU copies | 4.15 GiB/s | 8.16 GiB/s | 4.25 GiB/s |
| Copy synchronization attempts | 35,023 | 79,124 | 38,298 |
| Copy wait total | 19.70 s | 33.70 s | 22.30 s |
| Copy wait mean in window | 0.563 ms | 0.426 ms | 0.582 ms |
| Readbacks / pool exhaustion | 6 / 46 | 74 / 421 | 37 / 75 |
| GPU errors | 0 | 0 | 0 |

All recorded MJPEG decodes produced IOSurface storage, with zero decoder Data
fallbacks and zero predecode clock drops or superseded-before-decode drops.
Automatic server adaptation and capture cadence can vary: equal settings did not
produce equal fragment rates or received bytes. The table does not claim lower
network usage or directly comparable complete-frame throughput.

The native/decoded ratio is approximate because counters are sampled best effort
across actors. It is not an exact rejection trace. The remaining 426 decoded
fragments without a matching native commit are unclassified. In particular, the
diagnostic row's CPU-fallback field covers advanced video, while MJPEG Data
fallback describes decoder storage. Neither proves absence of every possible
MJPEG composition fallback; its native-fallback counter was not captured in AX.

Copy waits include GPU queue/completion and actor resumption, rather than pure
GPU execution. Accounted copy bytes are not measured hardware bandwidth
utilization. Increased pool exhaustion and readbacks remain material resource
pressure. The correction permits useful work previously discarded, while the
unbatched transactional candidate path still copies the entire Surface for
each partial composition.

## Visible output and interaction

Three saved steady observations per window show many narrow phase strips in
both control runs. The corrected observations show substantially fewer narrow
strips, with one or a few broader phase boundaries remaining. Returning to A
restores the narrow-strip pattern. This supports the identified cross-region
rejection defect as a contributor to the visual problem. Screenshot phases are
unaligned and no pixel reference or quality score was collected; atomic whole
frames are not established.

The separate marker checks confirmed **40/40** real Space presses for A and
**40/40** for B, in two batches of twenty with 100 ms holds. Screenshots confirm
counts 0, 20 and 40. Local queue p95 was **0.1 ms** for both; local send p95 was
**0.5 ms** for both, with zero send failures. These marker checks were separate
from the animated full-field load. They measure delivery and local aggregate
timing, not per-key input-to-presented or input-to-photon latency.

Cumulative session `currentDrawable` p95/max was **0.5/9.5 ms**, **0.5/16.8 ms**
and **1.0/11.9 ms**. Revision-request-to-presented p95 remained **33 ms** in all
three sessions; maxima were 45.7, 49.5 and 41.1 ms. These histograms include
warmup and earlier session activity; they are not subtracted between endpoints.
Long framed-receive gaps include deliberate idle pauses and do not reproduce
the historical selection-to-commit stall.

## Decision and restoration

Retain the correction and its overlap, desktop-write, lifecycle and immutable
snapshot protections. Next, reduce the repeated full-Surface copy and completion
waits by combining ready fragments into bounded Surface composition work, or by
safely catching up candidate regions. Do not wait indefinitely for every stream,
mutate a published Surface in place, or weaken stale-write protection to improve
the counters. The observed copy cost justifies this next optimization; its
performance and ownership correctness still need implementation and verification.

The server was gracefully restored to its original startup with no explicit
`streaming-video` option, default `off`, at PID 89994. Installed Maspice 0.6.1
was preserved, restored as the only viewer process, and visually confirmed with
the original marker fullscreen at count **0**. Both test viewers exited. The
full-field page was unloaded, the other VM and TLS relay stayed running, and no
release was published. Prior local verification remains **749** normal tests,
**749** ASan tests and **57** Maspice tests, plus the Release closure/signature
checks; this live-only follow-up did not rerun those tests.
