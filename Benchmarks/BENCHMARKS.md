# Local performance benchmarks

The opt-in `SpiceBenchmarks` target uses
[ordo-one/benchmark](https://github.com/ordo-one/benchmark) 1.38.1. It measures
fixed local workloads in Release mode on the same Apple Silicon/macOS toolchain
as the library. No SPICE server, SSH host, VM image, GLib client, or guest reset
script is needed.

## Run and compare

```sh
./Scripts/benchmark.sh list
./Scripts/benchmark.sh run
./Scripts/benchmark.sh run --filter 'JPEG/.*'
./Scripts/benchmark.sh baseline update before
# Make the code change, keeping inputs and machine configuration the same.
./Scripts/benchmark.sh baseline compare before
```

`make benchmark` runs the suite; `make benchmark ARGS="list"` lists it.
The script resolves the repository root, enables `SWIFTSPICE_BENCHMARKS=1`, and
uses `.build/benchmarks` for its build products, with Swift warnings treated as
errors. Ordinary `swift build` and
`swift test` do not include the benchmark target or its external dependencies.
The first benchmark invocation downloads the pinned package and its dependencies.
Baselines live in ignored `.benchmarkBaselines/`; retain them locally for
same-machine comparisons, not as universal pass/fail limits.

Export a result with the benchmark tool's standard format:

```sh
./Scripts/benchmark.sh run --format jmh --path .build/benchmark-results
```

The default metrics are wall time, process CPU time, throughput, and allocation count.
The framework's allocation interposer is enabled in this benchmark executable;
its overhead is part of both sides of a comparison. Measurements include five
warmup iterations and up to two seconds or 1,000 outer iterations per case.
Fast wire and reference-image cases use 1,000 inner operations and report
per-operation scaled results. No performance threshold is enforced until a
representative baseline and a justified tolerance have been established.

## Workloads and measurement boundaries

| Cases | Timed work |
| --- | --- |
| JPEG, 1080p and 4K | One accurate-quality decode of fixed quality-80, 4:2:0 input |
| MJPEG, 1080p and 4K | One decode using a warm stream handle and its IOSurface pool; fallback fails setup |
| LZ and QUIC references | Decode the small independent correctness fixtures; these measure per-image overhead, not full-screen throughput |
| GLZ reference sequence | Decode an ordered literal/cross-image sequence with a fresh dictionary per iteration |
| Wire, 64 KiB | Frame one mini-header message from contiguous input or 1 KiB chunks, including partial-message polling |
| Protocol Ping | Decode a fixed server Ping body through the production decoder |
| Surface, 1080p and 4K | Full fill, 64×64 update, COPY_BITS, IOSurface snapshot publication, or first CPU readback |

Fixture loading, input hashing, golden-result checks, Surface creation/seeding,
and cleanup are outside measurement windows. Surface operations start with fresh
state; CPU readback uses a fresh frame so it cannot accidentally measure the
cached `Data` accessor. Publication measures Surface-to-frame work, not a Metal
drawable or physical screen presentation. Errors fail the run instead of
silently replacing a missing native path with a different workload.

Record the commit (including whether it is dirty), Swift/Xcode version, macOS,
hardware, and workload selection alongside exported results. Compare on the same
machine with similar power/thermal conditions and no competing heavy workload.
A local microbenchmark does not establish network latency, input-to-visible
latency, or interoperability. For those investigations, connect `spice-probe` or
the actual client to an explicitly selected endpoint and profile that session.
The repository does not provision or manage remote test machines.

## Input provenance

`SpiceBenchmarks/Fixtures` contains:

- Exact copies of `lz-rgb32-6x3.json`, `quic-rgb32-7x5.json`, and
  `glz-reference-sequence.json` from `Tests/SpiceCodecsTests/Fixtures`. Their
  embedded generator metadata identifies the independent spice-common source.
  Keep these copies identical when updating the canonical test fixtures.
- `jpeg-manifest.json` records encoded-file and decoded packed-BGRA SHA-256
  values for deterministic 1920×1080 and 3840×2160 JPEGs. The benchmark script
  generates them in `.build/benchmark-fixtures` using `NativeJPEG/jpeg-check.c`,
  subsampling `2`, quality `80`, and progressive mode `0`; setup verifies both
  hashes. The images are not stored in the repository.

To regenerate a JPEG using the checked-in native artifact:

```sh
xcrun clang -O3 -std=c17 -Wall -Wextra -Werror \
  -I Artifacts/CTurboJPEG.xcframework/macos-arm64/CTurboJPEG.framework/Headers \
  Benchmarks/NativeJPEG/jpeg-check.c \
  Artifacts/CTurboJPEG.xcframework/macos-arm64/CTurboJPEG.framework/Versions/A/CTurboJPEG \
  -o .build/jpeg-check
.build/jpeg-check generate .build/jpeg-1920x1080.jpg 1920 1080 2 80 0
.build/jpeg-check decode .build/jpeg-1920x1080.jpg .build/jpeg-1920x1080.bgra 1
shasum -a 256 .build/jpeg-1920x1080.jpg .build/jpeg-1920x1080.bgra
```

Use 3840 and 2160 for the 4K case. Both widths have tightly packed 64-byte-aligned
BGRA rows, so the harness output hash is the same layout as `pixelsBGRA`.
The separate [NativeJPEG validation](NativeJPEG/README.md) retains scalar/Neon
comparisons and fully instrumented native ASan coverage.
