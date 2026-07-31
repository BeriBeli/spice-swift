# Native dependency artifacts

This directory contains the macOS static XCFrameworks that make SwiftSpice
self-contained at build and run time. Package consumers do not need Homebrew,
`pkg-config`, GLib, or spice-gtk.

The artifacts contain universal `arm64` and `x86_64` macOS slices and are built
from pinned, checksum-verified upstream sources by:

```sh
Scripts/build-native-dependencies.sh
```

The source versions, URLs, SHA-256 values, build flags, and minimum deployment
target are recorded in that script. See `THIRD_PARTY_NOTICES.md` for licenses.
