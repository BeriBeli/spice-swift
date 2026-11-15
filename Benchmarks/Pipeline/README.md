# Finite GPU pipeline measurements

This opt-in executable uses the production MJPEG, SurfaceStore and Metal
presenter paths without connecting to a peer. It does not allocate a drawable,
measure scanout, change production scheduling, or use the benchmark package.

Generate the two quality-80 4:2:0 JPEGs with the
[native quality runner](../NativeJPEG/README.md#current-codec-cost-and-quality-2026-11-13), then:

```sh
SWIFTSPICE_PIPELINE_BENCHMARKS=1 swift build -c release --disable-sandbox \
  --product spice-pipeline-benchmark -Xswiftc -warnings-as-errors
SWIFTSPICE_PIPELINE_BENCHMARKS=1 swift run -c release --skip-build \
  spice-pipeline-benchmark .build/jpeg-quality .build/pipeline-images
```

The second argument is optional; it explicitly writes three rendered fixture PNGs.

Each case has five warmup and thirty measured updates. A previously published
snapshot stays alive through the next update, exercising immutable revision
ownership. Composition is measured separately from snapshot publication. The
input is decoded once before these measurements. Full-frame verification and
explicit CPU pixel readback happen afterward. All output pixels matched the
expected decoded image/background, including the retained untouched region.

The [recorded M4 Pro results](RESULTS_2026-11-13.json) use the shipped 3.2.1 Neon
archive, Xcode 27.2 / Swift 6.4.2 and macOS 27.2.1:

| Surface | Update | Composition p50 / p95 ms | Extra GPU copy bytes/update |
| --- | --- | ---: | ---: |
| 1920×1080 | Full | 0.530 / 0.871 | 0 |
| 1920×1080 | 64×64 | 0.569 / 0.842 | 8,294,400 |
| 3840×2160 | Full | 0.780 / 1.531 | 0 |
| 3840×2160 | 64×64 | 1.338 / 1.975 | 33,177,600 |

This identifies full-surface revision synchronization for partial native video
updates. These copy counters exclude the composition write itself. They do not
show that arbitrary desktop mutations always copy; unleased canonical backing
can also be modified in place. Removing synchronization without preserving
published snapshots would violate pixel correctness.

For the 1080p full frame, separate offscreen presentation measured GPU execution
p50 **0.125 ms** at 1:1, **0.263 ms** at 2048×1152, and **0.347 ms** at 1536×864.
Nearest-rank p95 values were 0.131, 1.049 and 1.158 ms. The 1:1 rendered PNG was
byte-for-byte equal to the input frame's BGRA pixels. Scale changes use the
production sampling path; the output PNGs are retained for inspection.

Commit-to-completion includes CPU continuation scheduling; GPU execution uses
Metal's GPU start/end timestamps. Neither includes display-link scheduling,
`currentDrawable`, the compositor, input, or network time. Thirty warm-cache
samples establish the cost of these operations on this host; they do not prove
an optimization, a general GPU bottleneck, or the cause of a historical stall.
