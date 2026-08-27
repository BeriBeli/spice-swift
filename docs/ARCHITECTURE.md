# SwiftSpice architecture

This document describes the architecture implemented in the repository and the
rules for extending it. Validation evidence lives in [STATUS.md](STATUS.md), and
planned work lives in [ROADMAP.md](ROADMAP.md).

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
| `SpiceRenderer` | Data reference backing, revision journals, transactional drawing/candidate commit, image caches, and immutable frames |
| `SpiceIOSurface` | Process-wide bounded allocation, per-Surface revision rings, and immutable IOSurface leases |
| `SpiceMetalCompositor` | Transactional NV12-to-BGRA and IOSurface-backed BGRA clip/scale composition |
| `CompileMetalShaders` | SwiftPM build-tool plugin that compiles package shaders into a resource `.metallib` |
| `SpiceCryptoSecurity` | SPICE ticket encryption |
| `SwiftSpice` | Public session API, demand-driven desktop source, and optional macOS host integrations |
| `SpiceViewer` | Bundled SwiftUI/AppKit macOS client |
| `SpiceProbe` | Live listener and protocol integration probe |
| `SpiceTestSupport` | Deterministic transports and shared test fixtures |

Lower-level targets must not import the public facade or application target.
Unsafe pointers, C handles, AppKit objects, and device APIs stay in narrow
platform or interop modules.

## Concurrency and ownership

`SpiceSession` is an actor. It owns the active Main Channel, the advertised
child-channel set, connection supervision, credentials, and ordered control
event streams. Frame, cursor, and pointer-mode state bypass those streams and
flow through the session's stable `SpiceDesktopSource`. Each managed channel is
also an actor with one receive loop.

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
VideoToolbox / persistent MJPEG decoder -> SpiceMetalCompositor --+
                                                                 |
Display draw -> SurfaceStore canonical surface + damage journal --+-> committed revision
                                                                    |
                        visible demand -> DisplayFramePublisher ----+
                                              latest prepared frame |
                                                                    v
                          SpiceDesktopSource latest-only snapshot
                                      |
                         one-shot NSView display link
                                      |
               explicit MTKView full-screen-triangle render pass
```

Parsing, decoding, and rendering are transactional. A malformed stream, failed
decode, invalid cache reference, or capacity error must not partially modify a
surface or publish a cache entry.

Every Display destination is normalized as one bounded `PixelRegion` before
Surface mutation: `destination ∩ surfaceBounds ∩ union(clips)`. The canonical
form is ordered y bands containing sorted, disjoint x intervals; identical
adjacent bands are merged. No-clip and single-rectangle commands retain an
inline O(1)-space path. Wire clips are capped at 4,096 and canonical output at
65,536 segments, with checked half-open coordinates and failure before the
first Surface mutation.

Each non-empty wire fill or copy submits that complete region as one
`SurfaceStore` transaction. The actor acquires the required Surface operation
locks once, validates every translated source and destination, prepares backing
once, and then publishes one revision and mutation generation. Empty regions
and failed validation publish no pixels or damage and advance no Surface
transaction metrics. Cache entry publication remains ordered after successful
Surface commit. Cross-Surface locks are acquired in Surface-ID order.

The image cache and GLZ dictionary have explicit entry and byte limits. Shared
Display state uses actors and serial barriers so cross-channel invalidation and
GLZ dependencies follow protocol order.

Published frames preserve immutable packed-BGRA semantics. Eligible macOS
frames carry an IOSurface lease for Metal presentation and materialize packed
`Data` only when a CPU consumer first requests `pixels`; that readback is cached
and shared by value copies of the frame. Data-backed fallback frames keep the
same API and semantics. A surface cannot return to the bounded pool while a
frame or GPU command buffer still owns its lease.

Each Surface advances `lifecycleGeneration` across create/destroy and advances
`revision` only after a successful mutation. Publication commits only an exact
lifecycle/revision match, suppressing snapshots invalidated by concurrent
damage, destroy, or same-ID reconstruction.

Display commands always update the canonical Surface and append clipped damage.
Snapshot construction is demand-driven: no visible subscriber means no
IOSurface publication snapshot, while protocol drawing and revision tracking
continue. Each demanded Surface has at most one prepared frame and one
latest pending revision. Additional mutations coalesce until the prepared lease
is consumed; a lifecycle change, damage-history gap, or demand resume forces a
full-damage update. Public subscriptions use `AsyncStream.bufferingNewest(1)`
and carry frame, cursor, and pointer mode together, outside SwiftUI Observation.

Automatic Apple Silicon backing requires unified memory, Apple GPU family 7 or
newer, and a successful real IOSurface texture mapping. Each Surface has at
most three slots under one process-wide 256 MiB allocation budget. A published
canonical slot is immutable while a frame or GPU presentation lease is live.
After every lease releases, validated CPU-only damage may reuse it in place;
fallible GPU/native-video work still requires a distinct candidate. Lagging
slots catch up from bounded revision damage history with at most 64 losslessly
coalesced rectangles. An exact union-area check makes damage covering at least
half the surface a full upload without inflating touching L-shaped regions.
Only a successfully completed GPU candidate becomes canonical. Pool
exhaustion, unavailable Metal/IOSurface support, or GPU failure returns to the
bounded Data path without blocking Display. SwiftSpice itself supports only
Apple Silicon; the Data path remains a required fallback on that architecture.

VideoToolbox native frames and CoreVideo handles remain package-only. The
compositor maps NV12 Y/UV planes and performs color conversion, orientation,
nearest scaling, clipping, and candidate write in one command encoder. MJPEG
streams keep one TurboJPEG handle and a three-buffer IOSurface-backed BGRA pool;
fast DCT and upsampling apply only to streams, while standalone JPEG stays
bit-exact. At most two MJPEG decodes run concurrently per session. TurboJPEG
writes directly into a locked buffer and the compositor copies/clips/scales it
into the Surface without an intermediate full-frame `Data`; unavailable pool or
pipeline resources take the existing bounded Data fallback without waiting.

Unknown video color matrices, odd NV12 geometry, and frame-local mapping
failures use the CPU fallback for that frame. Pipeline or command-execution
failure disables Metal composition for the current stream generation.
Completion continuations retain pixel buffers and texture wrappers; no caller
waits synchronously for a GPU command buffer. VideoToolbox sessions request
real-time decoding and must report hardware acceleration; unsupported formats
and unavailable hardware surface as typed codec failures.

The AppKit presenter observes window occlusion and zero-size/detached states to
drive desktop demand. Its `NSView` display link is normally paused and wakes
only for an empty-to-ready latch transition. One tick selects the newest
snapshot and pauses again when no work remains. The `MTKView` uses explicit
drawing, obtains no drawable while idle, and renders directly from a cached
IOSurface texture using one full-screen triangle. Texture wrappers are bounded
to three; 1:1 and integer magnification use nearest filtering, other scales use
linear filtering. The final drawable is always completely covered because its
previous contents are not preserved. At most two GPU commands are in flight;
a busy GPU skips a tick without blocking the main actor, and frame leases live
through command completion.

Absolute remote cursors use cached `NSCursor` images. Relative cursors use a
cached Core Animation overlay whose position can change without redrawing the
framebuffer. Cursor-only desktop snapshots therefore do not create a Metal
command buffer.

`SpiceEndpoint.videoCodecPolicy` defaults to `.mjpegOnly`. The availability of a
hardware decoder or compositor never expands advertised video capabilities;
H.264 and H.265 remain mutually exclusive, explicit opt-ins.

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

TLS sessions must not migrate to plaintext. Connect-time virt-viewer
`host-subject` validation is supported, but a migration offer that supplies a
new destination certificate subject is still unsupported and remains an
explicit gate.

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
[STATUS.md](STATUS.md) for the current evidence and [ROADMAP.md](ROADMAP.md) for
the remaining acceptance gates.
