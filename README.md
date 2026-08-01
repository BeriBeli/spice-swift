# SwiftSpice

SwiftSpice is a native Swift 6 implementation of the SPICE client protocol for
Apple Silicon Macs. The repository contains a reusable library, a SwiftUI/AppKit
viewer, and a command-line integration probe. It does not depend on GLib.

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
| H.264 and H.265 | VideoToolbox decode and deterministic Rocky yuv420p interoperability are closed behind explicit opt-in; `.mjpegOnly` remains the default |
| Apple Silicon display path | Revisioned IOSurface backing and native NV12-to-Metal composition are implemented; the M4 Metal/VideoToolbox and live Rocky H.264/H.265 native paths pass with zero BGRA materialization or GPU errors, while CPU/frame performance plus M1 and real 1080p/4K window gates remain pending |
| UTF-8 clipboard, file transfer, and monitor configuration | Implemented and exercised with the richer Agent guest |
| Playback and Record | Implemented locally; audible playback and microphone capture remain external hardware gates |
| Smartcard and USB redirection | Implemented locally; real devices remain external gates |
| WebDAV | Explicit-root server and guest direct GET plus davfs2 mount/read are closed against the Rocky fixture |
| Semi-seamless and seamless migration | Implemented locally; live migration interoperability remains pending |

SPICE input messages carry physical PC scan codes. They do not transport
Unicode text or synchronize an IME composition session. UTF-8 text uses the
separate SPICE Agent clipboard path.

QUIC images use the exact `spice-common` 0.42 backend supplied as a static
XCFramework by this package, behind a bounded C shim that owns
alignment and non-local error handling. GRAY, RGB16, RGB24, RGB32, and RGBA
have byte-exact fixtures; malformed payloads remain transactional at the
Display boundary.

See [Project status](docs/STATUS.md) for the detailed evidence and
pending gates.

## Requirements

- Apple Silicon (arm64); Intel Macs are not supported
- macOS 26 or later
- Swift 6.3 and Xcode 26.6
- The Xcode Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`)

The package includes macOS static XCFrameworks for libjpeg-turbo, spice-common
QUIC, usbredir, and libusb. Supported SwiftPM builds select arm64, and packaged
apps contain exactly one arm64 executable slice; x86_64 builds are rejected.
Builds and packaged apps do not require Homebrew or `pkg-config`. The artifacts
are reproducible from pinned, checksum-verified upstream sources with
`Scripts/build-native-dependencies.sh`; licenses and provenance are recorded in
`THIRD_PARTY_NOTICES.md`.
The SwiftPM build-tool plugin compiles the package shader into a resource
`.metallib`; it does not search the working directory or Homebrew at runtime.

## Build and test

```sh
swift build --disable-sandbox -Xswiftc -warnings-as-errors
swift test --disable-sandbox -Xswiftc -warnings-as-errors
swift package --allow-writing-to-package-directory generate-spice-protocol --check
./Scripts/build-and-run.sh --package
```

`./Scripts/build-and-run.sh --stage` remains available as a development helper.
`--package` builds an arm64 release and verifies the staged native closure.

Run the viewer after staging it:

```sh
./Scripts/build-and-run.sh
```

Generated app bundles are written to the ignored `dist/` directory. Staged and
package bundles use an ad hoc signature. Release distribution still requires
Developer ID signing and notarization; third-party notices ship with the native
artifacts. The shader is installed at
`Contents/Resources/SwiftSpice_SpiceMetalCompositor.bundle/SpiceVideoCompositor.metallib`.

## Use the library

Add the package and import `SwiftSpice`. A session owns the Main Channel,
attaches advertised child channels, and publishes a bounded asynchronous event
stream. Control events preserve order and are not evicted by frame pressure;
pending frames are bounded and coalesced by Display channel and surface.

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

`SpiceFrame` keeps immutable packed-BGRA semantics. For IOSurface-backed
frames, `pixels` performs one lazy CPU readback and caches it; Metal presentation
does not trigger that materialization. Public IOSurface frames expose metadata,
not a mutable IOSurface or CoreVideo handle.

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

Advanced video remains explicit: pass exactly one of `--enable-h264` or
`--enable-h265`; omitting both keeps the `.mjpegOnly` capability policy.

TLS uses normal system certificate validation. The
`--tls-insecure-for-testing-only` option is available only for self-signed local
test servers.

For the nested QEMU live-validation harness, see the
[Apple/container guide](Integration/AppleContainer/APPLE_CONTAINER.md).

## Repository layout

```text
Sources/          SwiftPM library and executable targets
Tests/            Unit, corpus, integration, and golden-fixture tests
Plugins/          SwiftPM command and build-tool plugins
ProtocolSchema/   Pinned source for generated protocol declarations
Scripts/          Repository-wide build, packaging, and verification commands
Artifacts/        Reproducible native XCFramework dependencies
Integration/      Host-specific live interoperability fixtures
Benchmarks/       Performance tools and retained result summaries
docs/             Architecture, status, roadmap, and repository guidance
```

The public `SwiftSpice` target is a facade over smaller wire, protocol,
transport, channel, codec, rendering, and Apple integration targets. See the
[architecture](docs/ARCHITECTURE.md) for dependency boundaries and
[repository layout](docs/REPOSITORY_LAYOUT.md) for file-placement rules.

## Documentation

- [Documentation index](docs/INDEX.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Status and validation evidence](docs/STATUS.md)
- [Roadmap](docs/ROADMAP.md)
- [Repository layout](docs/REPOSITORY_LAYOUT.md)

## License

SwiftSpice is available under the [MIT License](LICENSE).
