# JPEG Neon validation — 2026-10-30

This is a codec-only measurement of the first improvement batch after the
0.4.4 source comparison. It does not measure displayed FPS, frame dropping,
network latency, Metal composition, or spice-gtk performance. The installed
Maspice application and the user's remote session were not used.

## Decision and source evidence

The local build still had `WITH_SIMD=OFF`. Git commit `a819332` introduced it
while building both arm64 and x86_64; neither that script nor the commit records
a concrete Neon failure or quality rationale. A historical reason cannot be
established from this evidence. SwiftSpice now supports arm64 only.

The checksum-verified libjpeg-turbo **3.2.0** source implements AArch64 SIMD using
Neon intrinsics. `simd/arm/aarch64/jsimdcpu.c` returns `JSIMD_NEON`, and
`simd/CMakeLists.txt` builds the intrinsics with Clang. The external NASM/Yasm
requirement applies to x86, as explained in upstream's
[build requirements](https://github.com/libjpeg-turbo/libjpeg-turbo/blob/3.2.0/BUILDING.md#build-requirements).
The source's `simd/jsimd.c` selects Neon accurate integer IDCT and fancy
upsampling functions. There was no current target/toolchain blocker in the
local build or validation.

The first batch therefore enables and **requires** this backend. Drawing/RAW/
cursor coverage is the next compatibility investigation, grounded in actual
peer messages; motion ACK coalescing and Viewer codec observability follow.
Opus, extended clipboard and peripheral management remain separate work.

## Artifact and quality contract

- Source version, URL and SHA-256 are unchanged. Only `CTurboJPEG` was rebuilt;
  QUIC/USB artifacts are unchanged. Headers, license and deployment target
  macOS 26.0 are retained.
- `WITH_SIMD=ON; REQUIRE_SIMD=ON` prevents silent scalar fallback during CMake
  configuration. Native closure checks require the accurate IDCT, fancy 4:2:0
  upsampling and BGRA color-conversion symbols, plus the recorded archive hash.
- Upstream's date-dependent `BUILD` string is pinned to `3.2.0`. Apple archive
  timestamps/uid/gid are normalized with `libtool -static -D` and
  `ZERO_AR_DATE=1`. Independent source/build/staging directories on the same
  toolchain produced matching bytes for all 13 regular-file/symlink entries in
  the XCFramework, including the static archive and provenance. Different
  compiler/SDK versions are not claimed to produce identical binaries.
- [BUILD_PROVENANCE.txt](../../Artifacts/CTurboJPEG.xcframework/BUILD_PROVENANCE.txt)
  records the final source hash, compiler, SDK, CMake, flags and artifact hash.
  Final archive SHA-256:
  `fbb21708cbe5a84e2d5a86d80dfdc9186a35c337a3b2b873e7aeda9906e4069e`.
- `TurboJPEGInterop` still passes only `TJFLAG_STOPONWARNING`: accurate integer
  inverse DCT and fancy chroma upsampling remain enabled for JPEG **and** MJPEG.
  No FASTDCT/FASTUPSAMPLE, reduced resolution or skipped frames were introduced.
  No stream scheduler, frame-order/generation check or Surface barrier changed.

## Correctness and memory safety

`Scripts/validate-jpeg-simd.py` verifies the source archive and shipped binary
hashes, builds an independent scalar baseline, and compares full decoded output
bytes with the shipped Neon archive. The C harness also asserts opaque alpha,
untouched 64-byte guards and untouched 64-byte-aligned row padding.

All **20 cases** matched exactly: dimensions 1×1, 9×7, 65×33, 1920×1080 and
3840×2160, each with 4:4:4, 4:2:2, 4:2:0 and grayscale sampling. The 65×33
cases are progressive. Fixtures are quality-80 deterministic sharp colored
edges, ramps, fine lines and textured tiles. Both decoders receive the exact
same JPEG bytes. This corpus is an equivalence check, not a claim to cover all
JPEG bitstreams.

The `--asan` run builds **both entire native libraries and the harness** with
AddressSanitizer, then repeats all 20 comparisons without performance claims.
It passed. The non-instrumented checked-in archive is not presented as having
instrumented native internals. [Native ASan evidence](ASAN_2026-10-30.json) is
separate from the [release measurement](RESULTS_2026-10-30.json).

Upstream's separate Neon Release build passed **332/332 CTest tests**. The
Swift JPEG/MJPEG tests also compare the existing six independent golden
fixtures (including CMYK, progressive, grayscale and ICC-bearing data) through
both IOSurface and forced Data paths, reusing one handle across format and
geometry changes. Full package validation is recorded in
[STATUS.md](../../docs/STATUS.md).

## Same-load measurements

Host: **Apple M4 Pro**, macOS **27.2**, Apple Clang **21.0.0**
(`clang-2100.3.34.2`), SDK **27.0**, CMake **4.4.5**. The native libraries and
harness use Release/-O3; the scalar build changes `WITH_SIMD` to `OFF`.

Each timed sample decodes **30 complete identical frames**, after five warmup
frames, with one persistent handle and `tjDecompressHeader3` on every frame.
Input/output allocation and file I/O are outside timing. Five trials alternate
scalar/Neon order. The table shows median **process CPU milliseconds per decoded
frame**; raw per-trial CPU/wall times, frame counts, JPEG and BGRA hashes are in
[the JSON record](RESULTS_2026-10-30.json).

| Size | Sampling | Scalar CPU ms/frame | Neon CPU ms/frame | CPU time reduction |
|---|---|---:|---:|---:|
| 1920×1080 | 4:4:4 | 11.060 | 7.022 | 36.5% |
| 1920×1080 | 4:2:0 | 7.436 | 4.304 | 42.1% |
| 3840×2160 | 4:4:4 | 44.322 | 28.600 | 35.5% |
| 3840×2160 | 4:2:0 | 30.208 | 17.594 | 41.8% |

These results support reduced CPU decode cost for this warm-cache synthetic
workload. They do not establish user-session speedup, latency, image-quality
recovery, M1 performance, changing-frame/cache behavior, or the overall viewer's
CPU/frame. Real 1080p/4K windows, the target server and older Apple Silicon
remain separate acceptance gates.

## Reproduce

The recorded measurements above used 3.2.0. The current dependency is 3.2.1;
the commands below validate that version and do not replace the historical measurements.

Use an otherwise idle Apple Silicon Mac with Xcode, CMake and Python 3.9+.
The native build owns/cleans its default temporary directory; an explicit work
directory below retains checksum-verified downloads for the validation script.
No Homebrew libraries are linked.

```sh
work="$(mktemp -d "${TMPDIR:-/tmp}/swiftspice-jpeg-evidence.XXXXXX")"
SWIFTSPICE_NATIVE_WORK_DIR="$work" Scripts/build-native-dependencies.sh --jpeg-only
Scripts/validate-jpeg-simd.py "$work/downloads/libjpeg-turbo-3.2.1.tar.gz" \
  --output "$work/jpeg-results.json"
Scripts/validate-jpeg-simd.py "$work/downloads/libjpeg-turbo-3.2.1.tar.gz" \
  --asan --output "$work/jpeg-asan.json"
Scripts/verify-native-closure.sh --artifacts-only
```

The upstream regression gate can be run separately on this retained source:

```sh
cmake -S "$work/src/libjpeg-turbo-3.2.1" -B "$work/upstream-tests" \
  -DCMAKE_BUILD_TYPE=Release -DBUILD=3.2.1 -DENABLE_SHARED=OFF \
  -DCMAKE_C_COMPILER="$(xcrun --sdk macosx --find clang)" \
  -DCMAKE_OSX_SYSROOT="$(xcrun --sdk macosx --show-sdk-path)" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
  -DWITH_SIMD=ON -DREQUIRE_SIMD=ON
cmake --build "$work/upstream-tests" --parallel
ctest --test-dir "$work/upstream-tests" --output-on-failure
```

Keep wanted JSON/log evidence, then remove the owned directory with `rm -rf "$work"`.
