# SwiftSpice

SwiftSpice is a native Swift 6 SPICE client protocol stack. It is currently in
the basic-desktop milestone. TCP/TLS, ticket authentication, Main bootstrap,
authenticated channel attachment, and cancellation cleanup are locally covered;
the basic Display, Cursor, and Inputs protocol paths are locally covered.

The supported protocol baseline is the official `spice-protocol 0.14.5`
release. Surface lifecycle plus real-wire COPY_BITS, solid DRAW_FILL, and
one-to-one RAW/surface DRAW_COPY are implemented and verified by an external
golden-frame fixture. Cursor wire decoding, bounded shape caching, and state are
implemented, as are physical scan-code and pointer Inputs messages. Live QEMU
validation, advanced draw modes, remaining cursor formats, and a complete app
scene remain pending. Inputs does not provide Unicode/IME text transport.

Stage D compression work includes strict JPEG wire parsing and a
TurboJPEG-backed decoder in the independent `SpiceCodecs` target. Decoding is
bounded and transactional: failed JPEG input cannot modify a Surface. Six
byte-exact libjpeg-turbo goldens cover RGB, grayscale, subsampled, progressive,
odd-sized, CMYK, and ICC-profile-bearing inputs; malformed warnings are rejected
without Surface mutation. ICC payloads are preserved through JPEG decoding but
are not color-managed. All C handles and pointer access are isolated in
`SpiceCodecInterop`.

The pure-Swift SPICE LZ 1.1 path supports RGB16, RGB24, RGB32, RGBA, XXXA, and
A8 images, with strict header/reference validation and byte-exact offline
fixtures from the `spice-common` C implementation. Alpha-bearing streams retain
alpha only when copied into an ARGB Surface. Palette LZ supports PLT1/4 LE/BE
and PLT8, including bounded inline/cached palettes and all protocol palette
invalidation messages.

QUIC images use the exact `spice-common` backend exported by Homebrew
`spice-gtk`, behind a bounded C shim that owns alignment and non-local error
handling. GRAY, RGB16, RGB24, RGB32, and RGBA have byte-exact fixtures;
malformed payloads remain transactional at the Display boundary.

Display now also implements the bounded shared image cache for RAW, JPEG, LZ,
and QUIC. `CACHE_ME`, lossless replacement, descriptor-only cache references,
targeted/all invalidation, and RESET are explicit actor-isolated state changes;
decode, rendering, or capacity failure cannot publish a cache entry. GLZ and
its dictionary are now implemented for RGB16/RGB24/RGB32/RGBA with bounded,
transactional cross-image references. A session-wide serial barrier enforces
`INVAL_ALL_PIXMAPS` wait dependencies across Display channels. ZLIB-wrapped GLZ
uses exact-size bounded system-zlib inflation and feeds the same dictionary.
Out-of-order cross-Display GLZ references use bounded, cancellation-safe actor
waits. Its corpus covers the bit-17 very-long offset form, one- and two-byte
image-distance extensions, and a 20-image concurrent dependency chain across
repeated dictionary rollover; the extreme byte streams match spice-common.
MJPEG streams now advertise only the implemented Display capabilities and
support create, ordinary/sized data, clip updates, destroy, and destroy-all.
Frames reuse the exact TurboJPEG backend and are clipped/scaled into SurfaceStore
in wire order with bounded per-stream state and transactional failed-frame
handling. A session-wide monotonic multimedia clock is seeded/reset by the Main
Channel; future frames wait for their timestamp, while frames already late—or
made late by decode—are dropped without mutating the Surface. UInt32 timestamp
wraparound is handled explicitly. Stage E Playback uses actual host sink-delay
reports to correct this shared clock.

Stage F advanced-video groundwork accepts bounded H.264/H.265 Annex-B access
units behind an internal decoder boundary. It validates NAL headers/counts and
sizes, accumulates AVC SPS/PPS or HEVC VPS/SPS/PPS, converts picture NAL units
to four-byte length-prefixed CoreMedia samples, and uses a synchronous
VideoToolbox decompression session. Native video/full-range NV12 output is
converted with bounded BT.601/BT.709-aware integer math to packed BGRA. Display
stream lifecycle owns and closes these decoder instances, and decoded frames
reuse the existing multimedia-clock and transactional SurfaceStore path.
Independent FFmpeg 8.1.2 software-encoded/software-decoded corpora cover H.264
High, H.264 Baseline parameter-set replacement, and H.265 Main. Real
VideoToolbox output matches those references with a maximum four-level RGB
rounding delta and exact dimensions/alpha. H.264/H.265 capability bits remain
unadvertised until live SPICE interoperability validates the transport contract;
MJPEG remains the only negotiated video codec.

Stage F migration control-plane groundwork strictly decodes Main Channel
MIGRATE_BEGIN, BEGIN_SEAMLESS, CANCEL, SWITCH_HOST, END, and destination
seamless ACK/NACK messages, including bounded NUL-terminated UTF-8 destination
and certificate-subject fields. `SpiceSessionEvent.migration` exposes supervised
preparing/ready/cancelled/committing/switching/completed/failed transitions. A
generation-tagged coordinator cancels superseded preparation, ignores late
completion, and permits commit only after target readiness. Main and advertised
child Channels are now authenticated into an isolated prepared target using the
source session ID and source Channel inventory; migration targets do not expect a
second MAIN_INIT/CHANNELS_LIST. Failure or cancellation closes that target without
disturbing source supervision. END sends MIGRATE_END to the target before
atomically adopting its whole Channel set and closing the source. TLS sessions
refuse plaintext migration downgrade, while certificate-subject validation remains
explicitly unsupported. Target-only Main Links can negotiate DST_DO_SEAMLESS with
strict ACK/NACK handling. Common-Channel MIGRATE now strictly sequences optional FLUSH_MARK
and opaque MIGRATE_DATA, seals ordinary writes at the migration boundary, waits
for every source Channel, and forwards state to the matching prepared target
connection before atomic adoption. Prepared target actors are not adopted: their
authenticated connections are rebound onto the existing Main, Display, Cursor,
Inputs, Playback, Record, and passive actors after an exact inventory check.
This preserves render/cache, Agent, input, audio, and multimedia-clock state
across the transport swap. Ordinary Main Links therefore advertise semi-seamless
and seamless migration; live interoperability validation remains pending a listener.

## Advanced peripheral channels

Smartcard, USB redirection, and WebDAV are locally integrated as supervised
channels. Their host-resource boundaries are deliberately explicit:

- Smartcard exposes reader/card/APDU lifecycle APIs but never enumerates host
  cards.
- USB redirection uses the exact `libusbredirhost` backend only after the app
  selects a bus/address; the guest device filter is enforced.
- WebDAV accepts a native backend only after the app supplies an authorized
  directory. It defaults to read-only; read-write DAV operations require an
  explicit policy. Without that backend, the bounded raw mux event bridge is
  used and no filesystem path is touched.

Published frames now also carry a bounded, geometry-keyed IOSurface lease from
an isolated interop target. The triple-buffer pool reuses a surface only after
the last frame lease is released, evicts idle mismatched surfaces within its
byte/frame limits, and falls back without blocking when every surface is in use.
The immutable packed-BGRA `Data` snapshot remains present on every public frame,
so CPU clients keep identical behavior. `SpiceDesktopView` now embeds a narrow
on-demand `MTKView`: IOSurface-backed BGRA frames are mapped directly to an
`MTLTexture` and blitted to the drawable without another CPU-side presentation
copy. A command-buffer completion hold prevents pool reuse during in-flight GPU
work. CPU-only frames still use the existing AppKit/CGImage path, and the cursor
remains an AppKit overlay shared by both paths.

Stage E Playback protocol support now covers bounded RAW S16LE MODE/START/DATA/
STOP plus volume, mute, and minimum-latency messages. Audio packets use a
dedicated bounded `playbackEvents` stream. `SpiceAudioPlaybackSink` connects RAW
S16LE packets to AVAudioEngine with a duration-bounded queue, startup buffering,
overflow resynchronization, underrun recovery, device-format conversion, and
periodic actual-delay reports that correct the shared multimedia clock.
The bundled macOS viewer now attaches this sink only when channel discovery
finds Playback channel 0. Its connected status bar exposes format/mute state and
bounded resynchronization, drop, and underrun counters; disconnected sessions
do not initialize AVAudioEngine.
Opus/CELT remain unsupported; live audible output still requires the deferred
QEMU/device acceptance gate.

Stage E Record support now implements strict START/STOP/VOLUME/MUTE decoding
and the required client RAW MODE → START_MARK → DATA ordering. The optional
`SpiceAudioCaptureSource` converts the default macOS input route to interleaved
S16LE with a duration-bounded newest-audio queue. Microphone consent and live
capture remain embedding-app/hardware acceptance responsibilities.
The bundled viewer discovers Record channel 0 but leaves capture off until the
user explicitly enables it. Only that action queries or requests macOS
microphone permission and attaches the source. Its status bar exposes permission,
server start/stop, mute, failure, and bounded overflow/drop state; disconnects
and reconnects return to opt-in rather than silently resuming capture.

Main Channel Agent transport now supports token-controlled connect/disconnect,
bounded 2048-byte packet framing, 16 MiB logical-message reassembly, and a
dedicated non-silent-loss `agentEvents` stream. `SpiceAgentManager` owns that
stream and negotiates monitor/reply plus clipboard/by-demand capabilities. It
implements UTF-8 grab/request/data/release ownership, accesses `NSPasteboard`
only through a thin main-actor bridge, and sends coalesced sparse/position-aware
monitor layouts. Agent UTF-8 clipboard transport remains separate from
physical Inputs scan codes and does not synchronize guest IME composition or
candidate state.
The bundled viewer leaves general-pasteboard synchronization off for every new
session. While disabled it drains bounded Agent events without reading or
writing `NSPasteboard`; an explicit Enable Clipboard action hands that stream to
`SpiceAgentManager`. The status bar reports readiness, host/guest ownership by
byte count, oversized rejects, and failures without retaining or logging text.
The same manager now remains attached for non-pasteboard Agent services. With
clipboard off it advertises monitor/reply/file-transfer services without the
clipboard/by-demand bits and ignores stale guest clipboard commands. The viewer
offers an explicit single-file `NSOpenPanel`, bounded progress/history, and
cancellation; selecting or sending a file never enables pasteboard access.
The monitor status item groups the latest authoritative guest inventory by
Display Channel ID and provides a complete layout editor. Rows accept explicit
0...255 monitor IDs, positive UInt32 dimensions, and signed Int32 positions.
An independent Agent support stream gates sparse IDs and positions against the
peer's explicit capabilities before submission; the protocol layer validates
them again. When several Display Channels report channel-local IDs, the draft
remaps request IDs sequentially and says so instead of claiming a lossless ID
round trip. Agent queued/sent/acknowledged state is shown separately: an Agent
ACK never rewrites the displayed geometry, and a request is marked applied only
after a later matching `SpiceSessionEvent.displayConfiguration` arrives.

After bootstrap, `SpiceSession` supervises the active channel receive loops and
publishes a bounded `AsyncStream<SpiceSessionEvent>`. Display bursts are reduced
to the newest frame per surface at a 16 ms cadence. `SpiceDesktopView` is the
library-level SwiftUI bridge: it draws immutable BGRA frames and alpha cursors
through a private AppKit view and returns physical keyboard and pointer events
through its `onInput` callback.

```swift
SpiceDesktopView(
    frame: frame,
    cursor: cursor,
    pointerMode: pointerMode
) { input in
    Task { try? await session.send(input) }
}
.task {
    for await event in session.events {
        // Update SwiftUI-owned frame, cursor, pointer-mode, and error state.
    }
}
```

Start the optional macOS audio consumer after connecting the session:

```swift
let audioSink = SpiceAudioPlaybackSink()
try await audioSink.start(session: session)

// Keep `audioSink` alive for the session, then stop it explicitly.
await audioSink.stop()
```

Start the optional macOS microphone producer after connecting. The embedding
app must declare `NSMicrophoneUsageDescription` and make capture state visible
to the user:

```swift
let audioSource = SpiceAudioCaptureSource()
try await audioSource.start(session: session)

// The source starts/stops the device only when the server sends Record control.
for await event in audioSource.events {
    // Surface capture state, dropped audio, and failures in the app UI.
}

await audioSource.stop()
```

Start the optional bidirectional UTF-8 clipboard consumer after connecting:

```swift
let agent = SpiceAgentManager()
try await agent.start(session: session)

// Immediate local publication is also available without waiting for polling.
await agent.publish("text for the guest")

// Repeated requests are coalesced while an Agent reply is pending.
try await agent.requestResolution(width: 1_440, height: 900)

try await agent.requestDisplayConfiguration(.init(monitors: [
    .init(id: 0, x: 0, y: 0, width: 1_920, height: 1_080),
    .init(id: 1, x: 1_920, y: 0, width: 1_280, height: 1_024),
]))

for await event in agent.events {
    // Observe readiness, ownership, size rejection, and failures.
}

// File transfer is always an explicit host-to-guest authorization.
let transferID = try await agent.sendFile(
    at: selectedFileURL,
    name: selectedFileURL.lastPathComponent
)
for await event in agent.fileTransferEvents {
    // Present guest approval, progress, completion, cancellation, and errors.
}

// Optional explicit cancellation:
await agent.cancelFileTransfer(transferID)
```

Automatic synchronization observes the general macOS pasteboard every 250 ms
by default. Applications should make that privacy behavior visible to users:
clipboard text may contain credentials or other sensitive data. File transfer
never scans folders or starts from pasteboard changes; the app must select and
authorize each regular file and retain any required security-scoped URL access.
The standard protocol is host-to-guest only, so guest-originated START/DATA is
rejected and no guest path is written on the Mac. This slice does not support
clipboard images, clipboard selections, or remote IME state. Monitor
request acknowledgement is published separately through
`displayConfigurationEvents`; actual guest geometry must still be taken from
subsequent `SpiceSessionEvent.displayConfiguration` messages. Display monitor
events include the Display Channel ID because Linux guests may expose several
heads on one channel while Windows guests may use one channel per display
device.

## Requirements

- Swift 6.3
- Xcode 26.6 on macOS 26 for the Apple build
- `jpeg-turbo` with `pkg-config` metadata (`brew install jpeg-turbo`)
- `usbredir` with `pkg-config` metadata (`brew install usbredir`)

Raw SwiftPM development products dynamically link the Homebrew codec and USB
backends used at build time. `./script/build_and_run.sh --stage` creates the
distributable app layout by recursively copying non-system dylibs into
`SpiceViewer.app/Contents/Frameworks`, rewriting every reference to `@rpath`,
and ad-hoc signing the local bundle. CI rejects absolute non-system dylib load
commands. Distribution builds must replace the ad-hoc signature with a real
Developer ID signature before notarization and include the licenses/notices
required by the bundled third-party libraries.

## Verification

```sh
swift build
swift test
swift package --allow-writing-to-package-directory generate-spice-protocol --check
./script/build_and_run.sh --stage
```

## Main Channel integration probe

The probe reads the ticket password from the environment so it does not appear
in the process arguments:

```sh
SPICE_PASSWORD='...' swift run spice-probe HOST PORT
SPICE_PASSWORD='...' swift run spice-probe HOST TLS_PORT --tls
```

The second command uses normal system certificate validation. For a self-signed
local test server only, `--tls-insecure-for-testing-only` is available as an
explicit opt-out.

## macOS viewer host

The package includes a native macOS viewer with two modes. Remote Session takes
a TCP or TLS endpoint and ticket password, supervises session events, presents
frames and cursors, and returns ordered physical keyboard and pointer input.
Offline Validation drives `SpiceDesktopView` with synthetic 640×360
IOSurface-backed BGRA frames on a deadline-based 30 fps schedule. The insecure
TLS option is prominently test-only, and the password is neither persisted nor
logged. Non-secret endpoint profiles are persisted separately. Each connection
attempt has a 10-second deadline and optional automatic reconnect uses bounded
1/2/4/8/16-second backoff. Build, stage, and launch the generated app bundle
with:

```sh
./script/build_and_run.sh
./script/build_and_run.sh --verify
./script/build_and_run.sh --telemetry
```

The same entrypoint is available as the Codex app `Run` action. Generated app
bundles live under ignored `dist/`; the SwiftPM executable product is
`spice-viewer`. A real listener is still required to close the external
end-to-end handshake and display/input interoperability gate.

To intentionally regenerate checked-in protocol sources after changing the
schema:

```sh
swift package --allow-writing-to-package-directory generate-spice-protocol
```

See [`docs/PLANS.md`](docs/PLANS.md) for the complete architecture and staged
roadmap, and [`docs/CURRENT_MILESTONE.md`](docs/CURRENT_MILESTONE.md) for the
validated/pending boundary.

## License

SwiftSpice is available under the [MIT License](LICENSE).
