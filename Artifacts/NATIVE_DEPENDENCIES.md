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

The source versions, URLs, SHA-256 values, build flags, and minimum deployment
target are recorded in that script. See `THIRD_PARTY_NOTICES.md` for licenses.
