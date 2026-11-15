# Actual-server MJPEG comparison, 2026-11-14

Keep the server's original video detection default, `off`, for now. The actual
peer can send native MJPEG, and a client clock-admission defect was corrected,
but the streaming runs still showed vertical phase bands and amplified full
Surface copies. Lower received traffic did not pass the presentation acceptance
gate. The historical 1,007.6 ms stall remains unexplained.

The [machine-readable record](../Benchmarks/Session/RESULTS_MJPEG_AB_2026-11-14.json)
contains counter differences, process intervals, build hashes and restoration
state. This follows the earlier [visible-window investigation](PERFORMANCE_VISIBLE_2026-11-14.md);
its measurements and archived evidence are unchanged.

## Server and controls

Independent SSH inspection confirmed direct QEMU 11.1.2 startup, Arch package
`spice 0.16.0-4`, and the loaded `libspice-server.so.1.15.0`. The original Linux
Lite process omitted `streaming-video`. QEMU executable and SPICE library SHA-256
hashes are in the record. The previous rejection of `gstreamer:h264` remains
user-reported evidence; that encoder probe was not repeated here.

An opt-in `--streaming-video off|all|filter` argument was added to the existing
`qemu-lab/lab.py` launcher. Its default is absent, preserving the original command.
It rejects an explicit mode on an already-running VM. AST/argv checks covered
both VMs with/without GUI and all three explicit modes: seven unchanged/limited
argv comparisons. Actual runtime arguments were also checked after each start.

Only Linux Lite was gracefully stopped and restarted. No forced termination was
used. CentOS PID 26919 and the existing TLS relay PID 3368 remained running.
The following stayed fixed:

- `virtio-vga,xres=1920,yres=1080`, `gtk,gl=off`, four vCPUs and 6144 MiB RAM.
- The original `linuxlite.vv`, existing CA/full subject validation, authentication
  secret, listeners and TLS relay. No traffic shaper or headless observer.
- One visible Maspice session using the same final Release executable, SHA-256
  `4f41f9f2467c59faf2fe43895f336cc3dd4b06933efbb6357dd0145390fe6f0f`,
  for all final `all`, `filter`, and `off` windows, in that order.
- Existing automatic desktop compression. The observed image types are recorded;
  identical options do not force identical automatic compression decisions.

The [QEMU documentation](https://www.qemu.org/docs/master/system/invocation.html)
defines the default detection mode as `off`. The
[SPICE host encoding documentation](https://www.spice-space.org/spice-user-manual.html#_host_video_encoding)
distinguishes native MJPEG from codecs requiring a GStreamer-enabled server build.
Enabling detection cannot add H.264 support to this installation.

## Triggering and diagnosing actual MJPEG

The original 30 FPS MP4 fixture still used desktop QUIC/LZ under `all`. The
unmodified-client control received approximately 92.89 Mbit/s under `off` and
93.37 Mbit/s under `all`, with no additional stream-create/data or MJPEG decode
activity during either steady playback window. These are workload rates, not
an H.264/MJPEG codec comparison. The MP4 is a 160×90, half-second loop scaled
fullscreen; it is not a native-resolution video quality benchmark.

The matching [QEMU 11.1.2 source](https://github.com/qemu/qemu/blob/v11.1.2/ui/spice-display.c)
splits changed pixels into 32-pixel-wide update rectangles. The
[SPICE 0.16.0 detector](https://gitlab.freedesktop.org/spice/spice/-/blob/v0.16.0/server/video-stream.cpp)
requires repeated compatible rectangles, including a 20-frame start condition.
`filter` also applies size and graduality checks. Fragmentation and varying
dirty bounds explain why a mode switch is not proof of streaming; no server
detector trace was collected to attribute every rejected MP4 rectangle.

A separate 750-byte, self-contained
[full-field fixture](../Benchmarks/Session/guest-fullfield.html) changes an entire
160×90 gradient at a requested 30 FPS, scaled to the guest desktop. A click enters
fullscreen and starts a finite 5400-callback sequence, nominally 180 seconds.
Timer scheduling is not a verified output frame rate or strict wall-clock limit.
Its transferred guest copy was SHA-256 verified. It caused 50 sustained MJPEG
streams under both `all` and `filter`.

The first `all` run received thousands of stream messages but decoded zero
frames. Two bounded counters were then added without changing scheduling:
late-before-decode drops and their maximum lateness. A fresh connection recorded
**4,988 drops out of 5,558 arrivals**, with a maximum lateness of just **20 ms**.
A later sample recorded 7,594 such drops, 2,642 decodes and 10,236 arrivals.
No synchronized audio playback anchor was active on this VM.

The client treated a send-time multimedia timestamp as a presentation deadline,
dropping any MJPEG frame already late by even one millisecond. With no playback
anchor, this can starve a live desktop stream. The correction makes MJPEG
without a playback anchor present the latest admitted frame immediately and
report a zero timing margin. The existing bounded per-stream replacement,
two-decode session limit, lifecycle checks and mutation/order guards remain.
Active playback retains its existing clock scheduling and late-frame rule.
This is a correction to MJPEG admission, not a fix for `currentDrawable`.

## Final comparison

Each mode received forty real Space presses through the actual viewer, in two
batches of twenty with 100 ms key holds. Screenshots confirmed 20 and 40 in all
three modes: **120/120**. Marker-window Display traffic was 88,949 / 98,132 /
98,263 bytes for `off` / `all` / `filter`. Local queue p95 was 0.2 / 0.1 / 0.2 ms;
local send p95 was 0.5 / 0.6 / 0.7 ms. Send failures were zero. These aggregates
do not measure per-key input-to-presented or input-to-photon latency.

The full-field workload results below use the final corrected executable:

| Mode | Display read rate | Client CPU | QEMU CPU | Canonical GPU copies | MJPEG data / decodes in window |
| --- | ---: | ---: | ---: | ---: | ---: |
| Original default `off` | 52.59 Mbit/s | 42.94% | 80.98% | 0.71 GiB/s | 0 / 0 |
| `all` | 15.35 Mbit/s | 49.42% | 50.38% | 3.07 GiB/s | 22,970 / 22,970 |
| `filter` | 13.60 Mbit/s | 41.28% | 49.20% | 2.80 GiB/s | 19,122 / 19,120 |

CPU percentages use one core = 100%. Display windows were 45.282 / 41.023 /
38.872 seconds; CPU windows have their own roughly 24-second endpoints, recorded
separately. They sample the same continuing workload, but are not exactly aligned.
The two outstanding filter arrivals are compatible with in-flight decode and
best-effort sampling; late-before-decode drops were zero in both streaming runs.
MJPEG decoded directly into IOSurface; its Data fallback count stayed zero.
H.264/H.265 requests and VideoToolbox decodes stayed zero.

Every counted canonical copy was **8,294,400 bytes**, a complete 1920×1080 BGRA
Surface. The windows counted 4,174 / 16,306 / 14,072 copies. Their total synchronous
copy waits were 3,188.04 / 9,862.56 / 8,495.52 ms, averaging 0.76 / 0.60 / 0.60 ms
per copy. Individual copies were short; frequency amplified the aggregate cost.
This identifies a real cost in the visible client, without establishing that it
caused the historical one-second stall.

The streaming windows also recorded 6 / 11 readbacks and 25 / 88 Surface-pool
exhaustions (`all` / `filter`), with zero GPU errors. Those resource fallbacks are
not zero-copy evidence. Metal drawable misses, GPU-busy skips, presentation
errors and command failures were zero in these samples.

`currentDrawable` p95/max at the full-field endpoints was 0.5/13.1 ms for `off`,
1.0/9.2 ms for `all`, and 1.0/9.3 ms for `filter`. The earlier original-binary
video control reached 14.7 ms maximum. These are session-cumulative summaries;
they are neither subtracted histograms nor proof the one-second outlier is fixed.

## Remaining presentation gate

Both streaming screenshots still showed many vertical regions at different color
phases. The desktop-drawing screenshot also caught a phase boundary, so these
unaligned screenshots do not establish a pixel-quality score or fully atomic
desktop presentation. The streaming result is not accepted as a complete-frame
quality or latency improvement.

The native composition counters increased by 15,183 / 13,054 while MJPEG decodes
increased by 22,970 / 19,120. Those counts are fragments, not output video FPS.
The difference is a diagnostic lead, not an exact classified drop count.
Source inspection found a Surface-wide video sequence shared by different
streams and whole-Surface mutation guards. Their rejection of a delayed fragment
after a newer non-overlapping fragment is a concrete hypothesis for the residual
bands. Server-side fragment timing and asynchronous publication also need to be
distinguished; no per-fragment causal trace was collected here.

The next implementation work should reproduce two disjoint MJPEG streams with
reversed decode completion and verify both regions, while preserving the existing
overlapping-stream and desktop-overwrite safety tests. Then trace real
decode-to-Surface rejection reasons and re-run this fixture. Composition batching
should address the repeated full-Surface candidate copies only after those
ordering rules are correct. Do not remove ownership or stale-write guards solely
to improve counters. Native 1080p/4K video, small text, real AV synchronization,
pixel-quality scores and per-key presented latency remain separate validation.

## Validation and restoration

- SwiftSpice: **744 tests** passed using `swift test --disable-sandbox --no-parallel
  -Xswiftc -warnings-as-errors`. The new parameterized test covers late and future
  MJPEG with no playback deadline and correct stream feedback. Existing clock,
  admitted-late, overlapping stream, overwrite and cancellation tests passed.
- Maspice: **57 tests** passed with the same warnings-as-errors test invocation.
  The Release app build, native dependency closure and signature verification
  passed. No native library artifact was changed; no new sanitizer run was made.
- The initial CPU helper sample that mislabeled Mach ticks as nanoseconds was
  excluded. All reported client CPU windows use the corrected 125/3 timebase
  conversion; QEMU uses `/proc` CPU ticks. Process identity and monotonic intervals
  were checked. Memory endpoints are gauges, not comparable peaks after reboot.
- Linux Lite was restored with the original launcher command, omitting the mode
  option. CentOS and the TLS relay stayed running. The opt-in launcher flag remains
  available, with its default unchanged.
- The test app was disconnected and closed. The unchanged installed
  `/Applications/Maspice.app` reconnected using the original file; the guest marker
  was visibly fullscreen at count zero. The animation page was unloaded.
  Both bundles share an ID: an initial restoration check found the diagnostic app
  had relaunched alongside the installed app. It was terminated, the CUA binding
  reset, and the installed 0.6.1 process was verified alone before final arming.
  Its PID/hash and the final screenshot are retained separately from measurements.
- The original package pin was restored; local editable dependency state remains
  for review. No installed app was overwritten and no commit, push or release was
  made. The earlier evidence archives remain unchanged.
