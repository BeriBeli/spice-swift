# Source quality, decode cost, GPU work and real viewer input

The remaining four investigations from the SwiftSpice analysis now have local
and live-peer evidence. On this peer/workload, bandwidth-limited desktop return
traffic delayed visual echo while the actual Maspice input queue remained short.
Codec selection is still an external validation gate: neither advertised policy
produced a video stream in the tested canvas workloads.

The [2026-11-14 visible-window follow-up](PERFORMANCE_VISIBLE_2026-11-14.md)
adds real Maspice copy/traffic measurements and successful MP4 playback checks.
It supersedes the setup-only MP4 limitation below while preserving this day's
original observations and their scope.

## Conditions and provenance

- Host: Apple M4 Pro, 12 logical processors, macOS 27.2.1 build 26B131;
  Xcode 27.2 build 27B52, Swift 6.4.2, Clang 21.0.0 (`clang-2100.4.1.1`).
- SwiftSpice base: `006d2aacc8ee6f7bab1d61975bab8eae20b8c5e5`, version 0.4.5,
  plus the working-tree benchmark and bounded presentation diagnostics changes.
- Native tests use the shipped libjpeg-turbo 3.2.1 arm64 Neon archive. Its SHA-256,
  complete per-trial timings, fixture hashes and quality values are in the
  [native record](../Benchmarks/NativeJPEG/RESULTS_2026-11-13.json).
- Actual input used the installed, unchanged Maspice 0.6.1 with SwiftSpice 0.4.5.
  The guest was Linux Lite 6.6 at 1920×1080, with a local fullscreen Chromium
  fixture, 100% browser zoom, and an exclusive SPICE session. The connection was
  the user's `linuxlite.vv`, retaining CA and complete subject validation.
- Power/thermal/refresh settings were not changed. Other user applications
  remained open. The requested 30 FPS fixture rate and the display's advertised
  maximum refresh rate are not measured output FPS.

## 1. Source quality and codec selection

The native corpus compares 4:4:4 and 4:2:0 at JPEG qualities 40 and 80, before any
presentation scaling. At 1080p, quality-80 PSNR is 32.84 dB for 4:4:4 and 18.12 dB
for 4:2:0. This deliberately fine chroma/noise pattern makes subsampling loss
large; it does not establish general desktop fidelity. Accurate decode flags
were unchanged. See the [method and table](../Benchmarks/NativeJPEG/README.md#current-codec-cost-and-quality-2026-11-13).

On the actual peer, the initial cached-canvas animation and a second variant
that uploads new pixels with `putImageData` were each observed for 15 seconds
under MJPEG-only and H.264+MJPEG capability settings. **All four observations
had zero MJPEG frames, zero advanced decoded frames and zero hardware decoder
sessions.** Encoded-frame probes produced no payloads. Consequently these runs
cannot compare MJPEG against H.264, infer JPEG sampling/quality, or establish
quality recovery from stream feedback. The reason the server chose desktop
drawing updates remains unknown; no server setting was changed.

A supplemental MP4-backed playback check could not run: two explicitly selected
fixture transfers reported `fixture_transfer_failed`, and the smaller fixture's
guest file lookup returned `ERR_FILE_NOT_FOUND`. The sampled transfer process
was waiting asynchronously rather than blocked in a local file-open syscall;
the exact failure stage was not captured. This failed setup is retained as a
limit, not counted as another video observation or evidence of server behavior.

Both settled static source exports matched the exact generated RGB pattern in
all 1920×910 pixels below the 170-row HUD: maximum component error and RGB MSE
were zero. These PNGs were exported after the measurement and diagnostics ended.
The production Metal presenter's separate 1:1 offscreen output also matched its
input BGRA bytes exactly. The 2048×1152 and 1536×864 outputs exercise production
scaling separately, with retained PNGs. This separates known source pixels from
scaling behavior without attributing an absent video stream to a codec.

## 2. Current MJPEG CPU cost

The current 3.2.1 quality-80 4:2:0 decoder used median **4.083 CPU ms/frame** at
1080p and **16.720 ms/frame** at 4K. At quality-80 4:4:4 the values were **6.580**
and **26.942 ms/frame**. Each median uses five trials of thirty measured frames,
after five warmup frames; one persistent handle and header parsing are retained.

This makes 4K MJPEG CPU cost a concrete candidate for workloads that actually
use MJPEG, especially at 60 Hz. It does not identify the bottleneck of the live
canvas runs, which decoded no video. These results are not a same-version
scalar/Neon comparison, and no new decoder speedup is claimed.

## 3. GPU composition, copy and presentation

The [opt-in pipeline tool](../Benchmarks/Pipeline/README.md) measures production
native-video composition while retaining the previous published snapshot.
Thirty measured updates follow five warmup updates; decoding is excluded.

| Surface/update | Composition p50 / p95 ms | Extra copy/update |
| --- | ---: | ---: |
| 1080p full | 0.530 / 0.871 | 0 bytes |
| 1080p 64×64 | 0.569 / 0.842 | 8,294,400 bytes |
| 4K full | 0.780 / 1.531 | 0 bytes |
| 4K 64×64 | 1.338 / 1.975 | 33,177,600 bytes |

Full-frame output/background verification passed with maximum component error
zero. Partial native video requires synchronization of the canonical surface;
its extra copy scales with the whole surface even for a 64×64 update. The
1080p offscreen GPU execution p50 was 0.125 ms at 1:1, 0.263 ms at 16/15 scale,
and 0.347 ms at 0.8 scale. These finite measurements do not include drawable
acquisition, compositor timing, input or transport.

The live `putImageData` MJPEG-policy observation received **9,018 desktop
revisions in 15.630 s** and recorded **74,798,899,200 GPU copy bytes** since
connect, including initial setup. The H.264-capability observation received
8,769 revisions in 15.097 s and recorded 72,733,593,600 copy bytes. Revisions are
individual desktop updates, not complete animation frames. The totals show
substantial revision-copy work in this workload, but they do not isolate its
contribution to latency. Batching compatible mutations while preserving wire
order and immutable published revisions is a justified next optimization target;
removing correctness barriers or increasing buffers without an A/B is not.

The actual viewer's network-profile samples recorded no drawable misses, GPU
busy skips or presentation errors. Its cumulative revision-request-to-presented
histogram p95 was 33 ms in each profile. This is a local display-stage histogram,
not a per-key latency measurement. No long GPU execution or presentation stall
was captured in these runs. The historical **1,007.6 ms** selection-to-commit
event remains unconfirmed; this work does not establish `currentDrawable` as
its cause or validate a runtime fix for it.

## 4. Actual Maspice input under shaped TCP transport

The [loopback relay](../Benchmarks/Session/shape-connection.py) kept TLS end-to-end
and applied shared directional rate limits to all four SPICE channel connections.
All profiles used the same fullscreen moving pixel fixture, a maximized host
window, and two batches of twenty Space presses, each held for 100 ms. The guest
counter was zero before each run and reached **40 in all three profiles**.

| Added transport conditions | Input queue p95 ms | Local send p95 / max ms | Queue current / peak | Guest count |
| --- | ---: | ---: | ---: | ---: |
| No delay/rate cap | 0.5 | 0.5 / 1.2 | 0 / 2 | 40 |
| 50±20 ms each direction; 20 Mbit/s | 0.1 | 0.5 / 0.8 | 0 / 2 | 40 |
| 25±10 ms each direction; 2 Mbit/s | 0.1 | 0.5 / 0.8 | 0 / 2 | 40 |

Each diagnostic after-state reported 84 submitted and 84 sent events, zero
coalesces and zero send failures. The eighty Space down/up events are accompanied
by setup/focus modifier events. Queue maxima of 45.1/43.3/40.1 ms cover the whole
collector lifetime, including setup, and cannot be assigned to a measured key.
The table uses approximate histogram p95 values, rounded by the viewer.

At 2 Mbit/s, immediate screenshots still showed counter 20 after all forty keys
had been submitted, while the local input FIFO was already empty. A later
screenshot showed 40 without reconnecting or changing the profile. This supports
display-return backlog as the dominant observed symptom under bandwidth stress.
The data does not divide it into server buffering, OS/TCP buffering, relay delay,
guest scheduling and display-channel framing. No per-key input-to-presented
timestamp was captured through the actual viewer, so no end-to-end p95 or exact
recovery time is reported. Identical Space keys test count/loss, not arbitrary
text, key ordering or clipboard behavior.

The relay queue reached its configured bound of sixteen chunks in each profile.
Its lifetime metrics include one connection error per profile, with teardown
included; they do not identify when or why that closure occurred. The viewer
reported zero send failures and all guest counters completed. This is ordered
TCP byte shaping, not packet-loss or real Wi-Fi emulation. Temporary credential
copies were removed, and the original connection/fullscreen zero-count marker
was restored afterward.

## Changes and validation

Production rendering/codec/input behavior is unchanged. Reusable additions are
the finite opt-in pipeline executable, quality corpus runner, explicit fixture
transfer/source-PNG export, controlled browser workload and bounded TCP shaper.
The temporary encoded-payload probe was removed before the final release build.
The measured guest HTML copies are retained separately; the reusable fixture
also removes an unused setup canvas and labels paused phases accurately.

The final Swift benchmark was built in Release with warnings as errors. All
741 package tests passed; the four explicit fixture-operation tests also passed
AddressSanitizer. The relay's 512 KiB loopback roundtrip, byte ordering, queue
bound, file permissions and signal cleanup passed its integration test.
These checks do not replace the pending live video-codec and historical-stall
acceptance gates described above.
