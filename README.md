# SwiftSpice

SwiftSpice is a native Swift 6 implementation of the SPICE client protocol for
macOS. The repository contains a reusable library, a SwiftUI/AppKit viewer, and
a command-line integration probe. It does not depend on GLib.

The protocol baseline is `spice-protocol` 0.14.5. The project currently covers
the core desktop path, compressed display formats, audio and Agent integration,
plus local groundwork for migration and peripheral channels. Features are only
advertised on the wire after their interoperability requirements are met.

## Project status

| Area | Current status |
| --- | --- |
| TCP/TLS, ticket authentication, Main Channel | Implemented and exercised against live QEMU/SPICE |
| Display, Cursor, physical keyboard and pointer input | Implemented and exercised against live QEMU/SPICE |
| RAW, JPEG, LZ, GLZ, ZLIB-GLZ, QUIC, and MJPEG display data | Covered by bounded decoders and offline golden fixtures |
| H.264 and H.265 | Locally decoded with VideoToolbox; capability advertisement awaits live interoperability |
| UTF-8 clipboard, file transfer, and monitor configuration | Implemented and exercised with the richer Agent guest |
| Playback and Record | Implemented locally; audible playback and microphone capture remain external hardware gates |
| Smartcard, USB redirection, and WebDAV | Implemented locally; real devices and guest mounting remain external gates |
| Semi-seamless and seamless migration | Implemented locally; live migration interoperability remains pending |

SPICE input messages carry physical PC scan codes. They do not transport
Unicode text or synchronize an IME composition session. UTF-8 text uses the
separate SPICE Agent clipboard path.

See [Current milestone](docs/CURRENT_MILESTONE.md) for the detailed evidence and
pending gates.

## Requirements

- macOS 26 or later
- Swift 6.3 and Xcode 26.6
- Homebrew development packages for `jpeg-turbo`, `spice-gtk`, `usbredir`, and
  `zlib`

Install the native dependencies with:

```sh
brew install jpeg-turbo spice-gtk usbredir zlib
```

Raw SwiftPM products link these Homebrew libraries dynamically. The staging
script copies non-system libraries into the app bundle and rewrites their load
paths for local distribution.

## Build and test

```sh
swift build
swift test
swift package --allow-writing-to-package-directory generate-spice-protocol --check
./script/build_and_run.sh --stage
```

Run the viewer after staging it:

```sh
./script/build_and_run.sh
```

Generated app bundles are written to the ignored `dist/` directory. Staged
bundles use an ad hoc signature. Release builds still require Developer ID
signing, notarization, and the notices required by bundled dependencies.

## Use the library

Add the package and import `SwiftSpice`. A session owns the Main Channel,
attaches advertised child channels, and publishes a bounded asynchronous event
stream.

```swift
import SwiftSpice

let session = SpiceSession()
let endpoint = SpiceEndpoint(host: "127.0.0.1", port: 5930)
let info = try await session.connect(
    endpoint: endpoint,
    credentials: SpiceCredentials(password: "ticket-password")
)

for await event in session.events {
    switch event {
    case .frame(let frame):
        // Present the immutable packed-BGRA frame.
        print("surface \(frame.surfaceID): \(frame.width)x\(frame.height)")
    default:
        break
    }
}

await session.disconnect()
```

On macOS, `SpiceDesktopView` presents frames and cursors and returns ordered
physical input events:

```swift
SpiceDesktopView(
    frame: frame,
    cursor: cursor,
    pointerMode: pointerMode
) { input in
    Task { try? await session.send(input) }
}
```

Optional host integrations are explicit. Applications decide when to attach
audio, microphone, pasteboard, file-transfer, USB, or WebDAV resources. In
particular, enabling clipboard synchronization allows guest text to reach the
general macOS pasteboard and may expose sensitive content.

## Command-line probe

`spice-probe` checks a real SPICE listener. The ticket password comes from the
environment so it is not exposed in process arguments:

```sh
SPICE_PASSWORD='...' swift run spice-probe HOST PORT
SPICE_PASSWORD='...' swift run spice-probe HOST TLS_PORT --tls
```

TLS uses normal system certificate validation. The
`--tls-insecure-for-testing-only` option is available only for self-signed local
test servers.

For the nested QEMU live-validation harness, see the
[Apple/container guide](Integration/AppleContainer/README.md).

## Repository layout

```text
Sources/                         Library and executable targets
Tests/                           Unit, corpus, and golden-frame tests
ProtocolSchema/                  Pinned SPICE protocol schema
Plugins/GenerateSpiceProtocol/   Checked-in protocol source generator
Integration/AppleContainer/      Nested QEMU live-validation harness
Scripts/                         Packaging and fixture helpers
docs/                            Architecture, roadmap, and validation status
```

The public `SwiftSpice` target is a facade over smaller wire, protocol,
transport, channel, codec, rendering, and Apple integration targets. See
[Architecture and roadmap](docs/PLANS.md) for the dependency boundaries and
design rules.

## Documentation

- [Documentation index](docs/README.md)
- [Architecture and roadmap](docs/PLANS.md)
- [Current milestone and validation evidence](docs/CURRENT_MILESTONE.md)
- [Apple/container live-validation harness](Integration/AppleContainer/README.md)

## License

SwiftSpice is available under the [MIT License](LICENSE).
