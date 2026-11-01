# Native dependency artifacts

This directory contains the macOS static XCFrameworks that make SwiftSpice
self-contained at build and run time. Package consumers do not need Homebrew,
`pkg-config`, GLib, or spice-gtk.

Each XCFramework contains a named static framework so Swift Build stages its
headers and module map inside that framework instead of merging unrelated
binary targets into a shared `include` directory. The dependency artifacts
contain exactly one `arm64` macOS slice. SwiftSpice supports Apple Silicon only,
and the library build verifies that dependency closure before use. The artifacts
are built from pinned, checksum-verified upstream sources by:

```sh
Scripts/build-native-dependencies.sh
```

Source versions, URLs, SHA-256 values, build flags and deployment targets
are recorded in the build scripts and per-artifact provenance files. See `THIRD_PARTY_NOTICES.md` for licenses.

For an isolated JPEG update, use `Scripts/build-native-dependencies.sh --jpeg-only`.
The libjpeg-turbo 3.2.1 artifact requires the arm64 Neon backend, including
accurate integer IDCT and fancy chroma upsampling; JPEG/MJPEG quality flags
are unchanged. `CTurboJPEG.xcframework/BUILD_PROVENANCE.txt` records its source,
toolchain, configuration and binary hash. The build pins upstream's `BUILD`
string and normalizes Apple archive metadata for repeatable output on the same
toolchain. `Scripts/verify-native-closure.sh` checks that hash and the required
Neon kernels. See [the correctness, native ASan and same-load measurement
record](../Benchmarks/NativeJPEG/README.md) for evidence and reproduction.

QUIC uses the unchanged spice-common C encoder/decoder from spice-gtk 0.42,
with the [standalone declarations and bounded bridge](../Sources/CSpiceQUIC/README.md).
Rebuild only QUIC with `Scripts/build-native-dependencies.sh --quic-only` and
Xcode. The pinned spice-gtk archive
is checksum-verified, and only its QUIC C codec is compiled; GTK and GLib are not linked.
`CSpiceQUIC.xcframework/BUILD_PROVENANCE.txt` records upstream provenance, exact
upstream and owned source hashes, compiler/configuration and binary hash. The
closure gate checks the owned hashes, public C symbols and headers. The upstream
LGPL-2.1-or-later text is included.
`make quic-artifact` checks the shipped archive using an unchanged C consumer
and a separately built upstream C oracle.
