# SwiftSpice architecture and roadmap

This document describes the architecture implemented in the repository and the
rules for extending it. Historical stage details and validation evidence live
in [CURRENT_MILESTONE.md](CURRENT_MILESTONE.md).

## Goals

SwiftSpice provides a native Swift 6 SPICE client stack without GLib. It aims
to support:

- TCP and TLS transport with SPICE ticket authentication
- Main, Display, Cursor, Inputs, Playback, Record, and Agent workflows
- bounded image and video decoding
- a Swift concurrency API with compiler-checked isolation
- native macOS presentation, input, audio, clipboard, and file integration
- optional Smartcard, USB redirection, WebDAV, and migration support

The package does not promise API or ABI compatibility with
`libspice-client-glib-2.0`. It also does not advertise protocol capabilities
only because a decoder or state machine exists locally. Live peer behavior must
close the interoperability gate first.

## System model

A SPICE session supervises independent protocol channels. Each channel has its
own connection, framing state, capabilities, serial numbers, and receive loop.
The Main Channel discovers child channels and coordinates session-wide state.

```text
Application or SpiceViewer
            |
            v
       SwiftSpice facade
       SpiceSession actor
            |
            +------ MainChannel
            +------ DisplayChannel(s) ---> codecs ---> SurfaceStore
            +------ CursorChannel
            +------ InputsChannel
            +------ Playback / Record
            +------ Smartcard / USB / WebDAV
            |
            v
 ChannelConnection + MessageFramer
            |
            v
       SpiceTransport
            |
            v
 Network.framework TCP or TLS
```

The session model has three consequences:

1. Messages remain ordered within a channel.
2. Independent channels can make progress concurrently.
3. A session can cancel, replace, or migrate a complete supervised channel set.

## Package boundaries

| Target | Responsibility |
| --- | --- |
| `SpiceWire` | Bounds-checked byte readers, writers, address resolution, and framing |
| `SpiceProtocol` | Message types, constants, capabilities, and generated protocol definitions |
| `SpiceTransport` | Transport abstraction |
| `SpiceTransportNetwork` | Network.framework TCP and TLS backend |
| `SpiceCore` | Handshake, channel connection, acknowledgement, and serial coordination |
| `SpiceChannels` | Main and child-channel state machines |
| `SpiceCodecs` | Bounded JPEG, LZ, GLZ, QUIC, ZLIB, and video input validation |
| `SpiceCodecInterop` | Narrow C interop for TurboJPEG, QUIC, and zlib |
| `SpiceVideoToolbox` | H.264/H.265 CoreMedia conversion and VideoToolbox decoding |
| `SpiceRenderer` | Surface state, drawing, image caches, and immutable frames |
| `SpiceIOSurface` | Bounded IOSurface allocation and lease ownership |
| `SpiceCryptoSecurity` | SPICE ticket encryption |
| `SwiftSpice` | Public session API and optional macOS host integrations |
| `SpiceViewer` | Bundled SwiftUI/AppKit macOS client |
| `SpiceProbe` | Live listener and protocol integration probe |
| `SpiceTestSupport` | Deterministic transports and shared test fixtures |

Lower-level targets must not import the public facade or application target.
Unsafe pointers, C handles, AppKit objects, and device APIs stay in narrow
platform or interop modules.

## Concurrency and ownership

`SpiceSession` is an actor. It owns the active Main Channel, the advertised
child-channel set, connection supervision, credentials, and session-wide event
streams. Each managed channel is also an actor with one receive loop.

Channel code follows these rules:

- Serialize writes through the actor that owns the connection.
- Preserve wire order for state-changing messages.
- Use structured tasks for supervised receive loops.
- Cancel all child work when the session disconnects or a prepared migration
  target is abandoned.
- Check a generation or state token after an `await` when actor reentrancy
  could make an operation stale.
- Do not store borrowed spans, raw pointers, or mutable buffers across an
  asynchronous suspension.

Expensive independent decoding may run outside a channel actor. The actor must
validate that the result still belongs to the active generation before it
commits state.

## Wire safety

Network data is never loaded directly as a Swift or C structure. Readers decode
little-endian fields explicitly and reject truncated input, integer overflow,
invalid enum values, disallowed flags, and trailing data where the protocol
requires exact consumption.

SPICE address fields are message-relative offsets, not native pointers. Every
resolution checks the complete range against the current message before a
decoder receives it.

Full and mini headers share the same framing boundary. Header mode is
connection state established during the Link handshake. Message size limits
are applied before allocating payload storage.

Generated protocol declarations come from
`ProtocolSchema/spice-0.14.5.json`. Regenerate them intentionally with:

```sh
swift package --allow-writing-to-package-directory generate-spice-protocol
```

CI and local verification use `--check` to reject stale generated output.

## Display pipeline

```text
Display wire message
        |
        v
strict command and image parsing
        |
        v
bounded decoder or cache lookup
        |
        v
transactional SurfaceStore mutation
        |
        v
immutable packed-BGRA SpiceFrame
        |
        +--> IOSurface / Metal presentation
        +--> CPU Data consumer
```

Parsing, decoding, and rendering are transactional. A malformed stream, failed
decode, invalid cache reference, or capacity error must not partially modify a
surface or publish a cache entry.

The image cache and GLZ dictionary have explicit entry and byte limits. Shared
Display state uses actors and serial barriers so cross-channel invalidation and
GLZ dependencies follow protocol order.

Published frames always retain an immutable packed-BGRA `Data` snapshot.
Eligible macOS frames also carry an IOSurface lease for Metal presentation. A
surface cannot return to the bounded pool while a frame or GPU command buffer
still owns its lease.

## Input and text

The Inputs Channel transports physical PC keyboard scan-code transitions and
pointer events. Key-up, key-down, modifier, and pointer ordering must remain
lossless.

Unicode text is a different protocol path. `SpiceAgentManager` uses SPICE Agent
clipboard messages for UTF-8 ownership, request, and data exchange. This does
not synchronize guest IME composition, candidate selection, or marked text.

Applications must expose clipboard synchronization as an explicit privacy
choice. File transfer also requires a user-selected regular file and never
starts from clipboard or directory scanning.

## Audio and multimedia timing

The Main Channel seeds a session-wide monotonic multimedia clock. Display video
and Playback use that shared timeline. Playback delay reports from the actual
host sink correct the clock rather than relying only on server hints.

Playback and Record queues are duration-bounded. Overflow, underrun, capture
permission, mute state, and device failure are observable application events.
Microphone access starts only after the application opts in and the server
starts the Record stream.

## Migration

Migration preparation builds an isolated authenticated target using the source
session ID and channel inventory. The source remains active until every required
channel reaches the migration boundary and the target is ready.

Commit adopts authenticated target connections into the existing channel
actors. This preserves render caches, Agent state, input state, audio state, and
the multimedia clock. Cancellation or failure closes the prepared target
without disturbing the source session.

TLS sessions must not migrate to plaintext. Certificate-subject validation is
still unsupported and remains an explicit gate.

## Host-resource boundaries

Peripheral channels never select host resources implicitly:

- Smartcard exposes protocol operations, while the embedding application owns
  reader enumeration and APDU policy.
- USB redirection starts only after the application chooses a bus and address.
- WebDAV receives an explicitly authorized root directory and defaults to
  read-only access.

WebDAV path handling rejects traversal and symbolic-link escape. Write methods
require an explicit read-write policy.

## Error handling

Public APIs return domain-specific Swift errors. Secrets must not appear in
logs, descriptions, or command-line arguments. Credentials use move-only
storage where practical and are released when the session disconnects.

Protocol errors identify the failed boundary without retaining clipboard text,
file contents, ticket passwords, or other sensitive payloads.

## Testing strategy

Verification is layered because no single test proves protocol compatibility:

- Wire tests cover truncation, malformed lengths, overflow, and mutation
  corpora.
- Protocol tests cover exact message layouts and capability handling.
- Fake transports exercise handshake, cancellation, channel supervision, and
  state-machine failures deterministically.
- Offline golden fixtures compare codec and renderer output with independent C
  or FFmpeg references.
- Viewer tests cover application state without requiring a live listener.
- The Apple/container harness exercises selected paths against QEMU,
  spice-server, and spice-vdagent.

Passing local tests is recorded separately from live interoperability. See
[CURRENT_MILESTONE.md](CURRENT_MILESTONE.md) for the current evidence.

## Roadmap

### Closed locally

- Wire framing, Link handshake, ticket authentication, and channel attachment
- Basic desktop Display, Cursor, and Inputs paths
- JPEG, LZ, GLZ, ZLIB-GLZ, QUIC, MJPEG, and shared image caches
- IOSurface and Metal presentation with a CPU frame fallback
- Playback, Record, Agent clipboard, file transfer, and monitor configuration
- Smartcard, USB redirection, WebDAV, and migration state machines
- H.264/H.265 parsing and VideoToolbox decoding behind unadvertised capabilities

### External gates

- Live H.264/H.265 capability negotiation and stream interoperability
- Audible Playback and real microphone Record behavior
- Real Smartcard and redirected USB devices
- Guest WebDAV mounting and filesystem behavior
- Live semi-seamless and seamless migration

### Extension rules

New work should keep these acceptance conditions:

1. Add strict wire parsing and negative tests before enabling a message path.
2. Bound memory, queues, caches, and retained continuations.
3. Keep failed operations transactional at their public state boundary.
4. Add an independent fixture or live peer check for codec and protocol claims.
5. Advertise a capability only after the implementation and its required
   interoperability gate are complete.

## Acceptance commands

```sh
swift build
swift test
swift package --allow-writing-to-package-directory generate-spice-protocol --check
./script/build_and_run.sh --stage
```

The nested QEMU gates have additional host requirements and retained artifacts.
Follow the [Apple/container guide](../Integration/AppleContainer/README.md)
instead of treating them as ordinary unit tests.
