# SPICE QUIC C codec

Production QUIC uses the unchanged spice-common encoder/decoder shipped in
**spice-gtk 0.42**, packaged as `CSpiceQUIC.xcframework` for arm64/macOS 26+.
Only the codec is compiled; GTK, GLib and the rest of spice-gtk are not linked.
This is the SPICE image codec, unrelated to the network protocol named QUIC.

`Scripts/build-quic-native.sh` downloads the pinned spice-gtk source archive,
verifies its SHA-256 and compiles `quic.c`, `quic_tmpl.c` and
`quic_family_tmpl.c` unchanged. Small platform macro headers replace the
GTK/GLib build dependencies. The artifact records its source URL, archive and
source checksums, compiler, flags, deployment target and binary checksum.

## Application boundary

- `quic.h` provides the upstream-compatible C declarations with standard includes.
- `shim.h` supplies the bounded BGRA bridge used by `SpiceCodecInterop`.
  It owns aligned input and the C `setjmp`/`longjmp`
  boundary, validates dimensions/output capacity and preserves typed errors.
- Grayscale decoding expands backwards within the output allocation, avoiding
  a temporary allocation that could be abandoned by a fatal callback.
- Positive output stride preserves logical top-down row order. GRAY, RGB16,
  RGB24, RGB32 and RGBA retain exact-pixel fixtures; alpha is straight for RGBA
  and opaque for the other formats.
- Application defaults remain a 16,384-pixel axis limit, 64 MiB encoded-input
  limit and 256 MiB decoded-output limit.

`SpiceCodecs` decodes QUIC images through `SpiceCodecInterop` and this C codec.

## Build and verification

```sh
./Scripts/build-native-dependencies.sh --quic-only
./Scripts/validate-quic.sh
swift test --disable-sandbox --no-parallel -Xswiftc -warnings-as-errors --filter QUICDecoderTests
```

Rebuilding and validating QUIC requires Xcode and Python. Closure checks verify
artifact/source hashes, headers, arm64 architecture and public C symbols.

[Native C tests](../../Tests/CSpiceQUICTests/README.md) compile one consumer
against an unchanged upstream header and link it to the independently built C
oracle and shipped artifact. They cover encode/decode bytes, pixels, padding,
guards, streaming, allocator failures, fatal callbacks and context reuse.
ASan/UBSan instrument the consumer and source-built oracle; the checked-in
archive itself is not sanitizer-instrumented. Swift tests exercise the actual
application bridge, limits, truncation handling and orientation.

The codec retains **LGPL-2.1-or-later** and Red Hat attribution. [COPYING](COPYING)
and the artifact license directory contain the upstream notice. The pinned
source and rebuild script allow recipients to modify and relink the codec.
Local tests do not establish live-peer or physical screen acceptance.
