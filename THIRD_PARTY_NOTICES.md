# Third-party native dependencies

SwiftSpice distributes static macOS artifacts built from these pinned upstream
sources:

- libjpeg-turbo 3.2.0 — IJG, zlib, and BSD-3-Clause licenses.
- spice-common QUIC from spice-gtk 0.42 — LGPL-2.1-or-later.
- usbredir 0.15.0 — LGPL-2.1-or-later library components.
- libusb 1.0.30 — LGPL-2.1-or-later.

Exact source URLs and SHA-256 values are in
`Scripts/build-native-dependencies.sh`. The checked-in static XCFrameworks can
be replaced by running that script, allowing recipients to relink modified
versions of the LGPL components. Upstream license texts are included in each
XCFramework after regeneration.
