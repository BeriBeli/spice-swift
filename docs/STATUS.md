# Current milestone and validation evidence

This document is the detailed engineering ledger for the current implementation.
For setup and first use, start with the [project README](../README.md). See
[ARCHITECTURE.md](ARCHITECTURE.md) for stable design rules and
[ROADMAP.md](ROADMAP.md) for pending acceptance gates.

Local tests, independent fixtures, and external interoperability are reported
separately. A locally implemented feature remains pending until its required
external gate is complete. The repository-backed Apple/container QEMU gate now
covers a booted arm64 guest plus live Main, Display, Cursor, Inputs, and selected
Agent behavior, including system-trusted TLS.

## Navigation

- [Stage B: connection and live QEMU closure](#stage-b-local-closure)
- [Stage C: basic desktop](#stage-c-delivered-so-far)
- [Stage D: compressed display](#stage-d-delivered-so-far)
- [Stage E: audio and Agent integration](#stage-e-local-closure)
- [Stage F: video, migration, and peripheral channels](#stage-f-advanced-video-groundwork)
- [Acceptance commands](#acceptance-commands)

## Stage B local closure

- Swift 6 actor-based TCP and TLS transport using Network.framework.
- System certificate validation by default and an explicitly named insecure
  policy reserved for tests.
- Caller-anchored private PKI supports both modern hostname/SAN/EKU validation
  and an explicit virt-viewer-compatible full `host-subject` policy for legacy
  certificates. Fixed-date local fixtures cover chain, subject, and validity
  failures; the reported real Ravada endpoint remains an external acceptance
  gate.
- SPICE Link handshake, Full/Mini header negotiation, and ticket authentication.
- RSA-OAEP-SHA1 ticket encryption with the reference trailing NUL convention.
- Main Init, Attach Channels, Channel List, Ping/Pong, and ACK flow control.
- ChannelFactory authenticates every discovered channel with the Main session ID.
- Session-scoped credential storage supplies per-channel temporary password
  copies and clears retained bytes when the Session disconnects or fails.
- Disconnect and cancellation during channel attachment close Main, attached,
  and currently attaching transports.
- `spice-probe` provides the TCP/TLS integration entrypoint.

## Stage B live QEMU closure

- Apple/container 1.2 ran an arm64 QEMU 8.2.2 endpoint with KVM using a custom
  Linux 6.18.5 kernel built from Apple containerization 0.40.1. `/dev/kvm` and
  the KVM guest virtual-timer interrupt were present inside the container.
- Host loopback publishing connected `127.0.0.1:15930` to the container SPICE
  listener. A correct ticket completed Main Init and Channel List; an incorrect
  ticket was rejected by QEMU with code 7.
- The live Main transcript reported Display type 2 id 0, Cursor type 4 id 0,
  and Inputs type 3 id 0.
- A self-signed container TLS listener completed the same handshake with the
  explicitly test-only insecure trust policy. No certificate was installed in
  the macOS system or user trust store.
- A system-trust connection to that untrusted certificate now surfaces its
  terminal TLS trust error instead of hiding it behind the 10-second
  establishment timeout. A silent peer that never completes TLS still follows
  the bounded timeout path; both state paths have local regression coverage.
- After explicit authorization, a one-day local CA was temporarily installed as
  a trust root in the login keychain. macOS SSL evaluation accepted its
  IP-address leaf for `127.0.0.1`, and the normal `--tls` probe authenticated
  Main plus independently attached Display 2/0, Cursor 4/0, and Inputs 3/0
  channels. The test CA was then deleted by its exact SHA-1 fingerprint;
  keychain lookup returned not-found and the leaf returned
  `CSSMERR_TP_NOT_TRUSTED`, confirming that no temporary trust remains.
- QEMU's 256,000-byte bandwidth-probe PING padding exposed and closed a decoder
  interoperability bug; PING now decodes its fixed prefix while other generated
  messages retain strict trailing-byte rejection.
- A minimal Alpine initramfs booted under nested KVM with Apple's custom arm64
  kernel, virtio-gpu framebuffer, virtio keyboard, and virtio mouse. The guest
  reached a 1280x800 framebuffer and continuously changed its tty0 contents.
- Live Display initially stalled because the client omitted
  `SPICE_MSGC_DISPLAY_INIT`. The generated 14-byte client message and Display
  bootstrap are now implemented and covered by a wire test. A subsequent live
  probe received one monitor configuration and 135 immutable 1280x800 frames.
- The same probe received a Cursor initialization, keyboard modifier state, and
  two mouse-motion acknowledgements. The guest's raw input device recorded the
  injected A-key transition as EV_KEY code 30, proving the Inputs path reached
  the booted guest rather than ending at the SPICE server.
- `Integration/AppleContainer` now retains the QEMU/SPICE Containerfile, pinned
  Alpine 3.22.5 initramfs recipe, guest init, lifecycle cleanup, live probe, and
  guest-side scan-code assertion. The Alpine source archive is verified against
  SHA-256 `3fbc6285032ed46821b511292633d7b2a6306a2e254f590e92bdafff56cf2f70`;
  generated artifacts remain ignored. The custom Apple containerization 0.40.1
  / Linux 6.18.5 KVM kernel remains an explicit external input because it is a
  29 MB locally built artifact.
- A clean initramfs regenerated by that recipe passed the strict harness with
  ticket authentication, two Display/Cursor channels, two monitor
  configurations, 57 immutable frames including the live 1280x800 framebuffer,
  keyboard-modifier state, two mouse-motion acknowledgements, and a guest raw
  `EV_KEY` code-30 value-1 record.
- A richer pinned Alpine 3.22 Agent initramfs now adds Xorg 21.1.19,
  spice-vdagent 0.22.1, xrandr, and xclip. One combined live run closed exact
  30-byte host-to-guest file transfer, 26-byte host-to-guest and 27-byte
  guest-to-host UTF-8 clipboard payloads, two Display heads, Inputs delivery,
  and an applied 1440x600 XRandR layout composed from 800x600 and 640x480
  outputs.
- Linux spice-vdagent advertises clipboard-by-demand without the obsolete
  legacy clipboard bit. Clipboard readiness now follows that interoperable
  capability shape and has a focused regression test.
- For virtio-gpu, spice-server intercepts `VD_AGENT_MONITORS_CONFIG` and calls
  QEMU's `client_monitors_config` UI-info path instead of forwarding the packet
  to guest vdagent; an Agent reply is therefore absent by design. QEMU trace
  recorded head 1 as 640x480 and head 0 as 800x600, connector hotplug reached
  Xorg, and the bare guest's explicit auto-layout policy applied both outputs.
  Display Channel messages then reported both heads and produced frames.
- The topology change also showed that spice-server may re-emit Cursor Init on
  an existing Cursor Channel. Cursor Init is now an authoritative state/cache
  reset, with a regression test, rather than a false protocol failure.

## Stage B external TLS gate closure

- Both trust directions are now closed: a temporarily system-trusted local chain
  completes normal `--tls` Main and child-channel attachment, while the same
  self-managed chain fails after trust removal. Terminal certificate/trust
  `.waiting` errors propagate as TLS failures, while a genuinely stalled
  handshake remains covered by the bounded negative-timeout listener test.

## Stage C delivered so far

- Generated and dispatched Display Surface Create (314) and Destroy (315).
- Bounded actor-isolated SurfaceStore for 32-bit xRGB and ARGB surfaces.
- RAW 32-bit bitmap draw-copy with top-down and bottom-up row orientation.
- Solid fill and overlap-safe COPY_BITS execution primitives.
- Immutable frame snapshots for the later presentation/coalescing boundary.
- Bounds, stride, allocation-limit, duplicate-surface, and malformed-input tests.
- Source-validated wire models for DisplayBase, signed Rect/Point, inline Clip
  rectangles, Brush, QMask, Image descriptors, RAW Bitmap, and Surface images.
- Strict decoding for COPY_BITS (104), DRAW_FILL (302), and DRAW_COPY (304),
  including relative image offsets and bounded pointer payload validation.
- DisplayChannel dispatch into SurfaceStore with clip intersection, solid PUT
  fills, one-to-one RAW/surface DRAW_COPY, COPY_BITS, Ping/Pong, and ACK handling.
- A complete Mini-header transcript test from Surface Create through real draw
  wire bodies to the expected framebuffer and Surface Destroy.
- An external JSON golden-frame fixture that replays Surface Create, DRAW_FILL,
  RAW DRAW_COPY, and COPY_BITS and verifies the exact BGRA framebuffer.
- Generated Inputs client/server messages plus an actor-isolated Inputs channel
  for physical PC scan-code transitions, lock modifiers, relative/absolute
  pointer motion, button masks, and server motion acknowledgements.
- Strict Cursor Init/Reset/Set/Move/Hide/Trail and cache-invalidation decoding,
  with bounded cursor-shape caching and actor-isolated visible cursor state.
- Session channel dispatch now constructs Display, Inputs, and Cursor actors;
  unsupported channel types remain passive authenticated connections.
- Session now supervises Main, Display, Inputs, and Cursor receive loops after
  bootstrap. A channel failure cancels its peers, closes every connection,
  clears credentials, and publishes a typed failure event.
- The public Session event stream exposes mouse-mode, keyboard-modifier,
  cursor, surface-destroy, failure, disconnect, and immutable frame events with
  an ordered mailbox. Control events are never evicted by frame pressure;
  pending frames are bounded to 64 display/surface entries and coalesce only
  within their surrounding control-event segment.
- Display frame bursts are scheduled at a 16 ms cadence with at most 16
  surfaces pending per publisher. Snapshots commit only an exact
  lifecycle/revision match; damage during a snapshot is requeued, while
  destroy or same-ID reconstruction suppresses the stale frame.
- `SpiceDesktopView` is a thin `NSViewRepresentable` around one private AppKit
  framebuffer view. It performs aspect-fit BGRA drawing, alpha-cursor overlay,
  first-responder handling, physical macOS-keycode to PC-XT mapping, relative
  or absolute pointer input, buttons, and scroll-wheel events.

Inputs transports physical key transitions, not Unicode text or IME
composition. The AppKit bridge draws the supported alpha cursor as a remote
overlay; native host-cursor replacement and other cursor pixel formats remain
pending. Cursor color8 and color24 payloads are explicitly rejected until their
palette/pixel formats are implemented.

## Deferred Stage C enhancements

- Add scaled DRAW_COPY, pattern brushes, masks, and additional ROP operations.
- Add a sample SwiftUI application scene and observable connection model on top
  of the library-level bridge.
- Add native host-cursor replacement and remaining decoded cursor format
  conversion.
- Add focus/capture policy, mouse-motion ACK backpressure, and richer keyboard
  edge recovery around the AppKit input bridge.

## Stage D delivered so far

- Added the independent `SpiceCodecs` target with a Sendable async decoder
  interface, typed codec errors, immutable BGRA output, and explicit encoded,
  decoded, and dimension limits.
- Added strict Display wire decoding for `SPICE_IMAGE_TYPE_JPEG` (105), including
  bounded `data_size` handling and truncated-payload rejection.
- Added a TurboJPEG decoder using `@concurrent`; socket parsing and Surface
  mutation remain serialized in DisplayChannel while CPU decode runs outside
  its inherited actor executor.
- Added a `CTurboJPEG` SwiftPM binary target backed by the package's arm64
  static XCFramework. All C handles and unsafe buffer access are isolated in
  the `SpiceCodecInterop` target.
- TurboJPEG validates the JPEG header dimensions before writing into a bounded,
  preallocated destination and treats decoder warnings as failures. RGB-family
  inputs decode directly to BGRA; CMYK/YCCK inputs use TurboJPEG's required
  four-component output followed by a bounded, rounded CMYK-to-BGRA conversion.
- DisplayChannel accepts an injected JPEG decoder and commits decoded pixels to
  SurfaceStore only after full decode and validation. A failed decode leaves the
  destination Surface byte-for-byte unchanged.
- Added checked-in JPEG plus RGB goldens generated by libjpeg-turbo 3.2.0,
  along with bounds, truncated-corpus, ICC-marker, and warning-path tests.

The TurboJPEG backend is byte-for-byte identical to six checked-in
libjpeg-turbo 3.2.0 goldens covering baseline 4:4:4, grayscale, 4:2:0,
progressive encoding, odd dimensions, CMYK, and an ICC-profile-bearing image.
The ICC case verifies transport and decoding of the profile-bearing JPEG; the
decoder does not currently perform ICC color management. Removing the terminal
EOI from a valid JPEG exercises libjpeg-turbo's warning path, and both the codec
boundary and a real DisplayChannel integration test confirm rejection without
Surface mutation. The local Stage D JPEG acceptance gate is closed.

The TurboJPEG portion is statically linked from the checked-in, reproducible
native dependency artifact.

### LZ RGB-family slice

- Added strict Display wire support for `SPICE_IMAGE_TYPE_LZ_RGB` (101) using
  the protocol's bounded BinaryData payload.
- Added a pure-Swift SPICE LZ 1.1 decoder for RGB16, RGB24, RGB32, RGBA, XXXA,
  and A8 streams. It
  validates the big-endian magic/version/type/dimensions/stride/top-down header,
  uses a prebounded output buffer, validates each color/alpha plane and every
  literal/back-reference, and rejects truncation and trailing bytes.
- Added independent fixtures for all six supported formats, generated offline
  by the fixed `spice-common` C `lz.c` encoder/decoder. Swift output matches all
  reference BGRA bytes exactly, including overlapping back-reference behavior.
- Codec output now records whether alpha is meaningful. Display and
  SurfaceStore preserve it only for an ARGB source copied into an ARGB Surface;
  xRGB destinations remain opaque.
- LZ DRAW_COPY follows the same transactional boundary as JPEG: only a fully
  decoded immutable image reaches SurfaceStore.

The LZ RGB family is locally closed.

### LZ palette slice

`SPICE_IMAGE_TYPE_LZ_PLT` and its palette path are also locally closed:

- Added strict `SPICE_IMAGE_TYPE_LZ_PLT` parsing for canonical inline-palette
  pointers and cached palette IDs, with bounded entry and compressed-data sizes.
- Added pure-Swift PLT1 LE/BE, PLT4 LE/BE, and PLT8 expansion. Five independent
  `spice-common` fixtures match visible BGRA pixels byte-for-byte, including
  packed-row padding.
- DisplayChannel uses a bounded palette cache, commits `PAL_CACHE_ME` only after
  successful decode/render, resolves `PAL_FROM_CACHE`, and handles palette 107,
  palette-all 108, and Display RESET 103 invalidation.
- Missing palettes, malformed streams, invalid indices, bad pointers, and every
  truncated fixture fail without changing the Surface or populating the cache.

### QUIC exact slice

- Added strict `SPICE_IMAGE_TYPE_QUIC` BinaryData parsing and a bounded async
  decoder for GRAY, RGB16, RGB24, RGB32, and RGBA.
- The exact backend uses the `spice-common` QUIC implementation supplied by the
  package from `spice-gtk` 0.42. A C-only shim copies input to aligned words, catches the
  backend's non-returning error callback with `setjmp`/`longjmp`, rejects
  warnings, and writes only into a preallocated BGRA buffer. Swift never holds
  a QUIC context or C pointer.
- Five independent 7x5 fixtures generated by the same C encoder/decoder match
  byte-for-byte. Every truncated byte prefix and a mutated magic corpus return
  typed errors without crashing.
- Display preserves QUIC's bottom-up row order and RGBA alpha semantics. A
  failed decode leaves the destination Surface unchanged.

### Shared image cache slice

- Corrected the source-backed image type values to `SURFACE` 104 and `JPEG`
  105; `FROM_CACHE` 103 and `FROM_CACHE_LOSSLESS` 106 are now descriptor-only
  image references.
- DisplayChannel owns a bounded shared image cache with both entry-count and
  decoded-byte limits. RAW, JPEG, LZ palette/RGB, and QUIC sources are decoded
  once per command, even when several clip rectangles are present.
- `CACHE_ME` inserts only after every clipped Surface write succeeds.
  `CACHE_REPLACE_ME` accepts only a lossless source replacing an existing lossy
  representation, and `FROM_CACHE_LOSSLESS` rejects JPEG-derived entries until
  that replacement completes. Repeated `CACHE_ME` and targeted invalidation use
  the reference-count semantics of spice-gtk's session-shared image cache.
- Missing references, dimension disagreement, invalid
  flags, decode failure, and capacity overflow fail before publishing cache
  state. Cache byte accounting is updated on replacement and invalidation.
- Display `INVAL_LIST` 105 and `INVAL_ALL_PIXMAPS` 106 remove the corresponding
  shared images. RESET 103 preserves the session image cache, matching
  spice-gtk, while clearing the Display palette cache.

### GLZ RGB and dictionary slice

- Added strict `SPICE_IMAGE_TYPE_GLZ_RGB` (102) BinaryData parsing and Display
  execution for RGB16, RGB24, RGB32, and RGBA streams.
- The pure-Swift decoder validates the 33-byte big-endian GLZ header, dimensions,
  stride, image IDs, window-head distance, every literal, same-image reference,
  cross-image reference, and exact stream consumption before publishing output.
- The GLZ dictionary is an actor shared by all Display channels in one Session.
  It supports out-of-order IDs, contiguous tail-gap closure, protocol-directed
  window eviction, image/byte limits, and atomic commit only after full decode.
- A four-image literal/cross-image RGB32/RGBA sequence was checked against the
  exported spice-common decoder from spice-gtk 0.42.3 and is stored as an
  offline golden fixture. RGB16/RGB24 and malformed/truncated cases have focused
  coverage; failed input leaves the dictionary unchanged.
- Multi-Display out-of-order references now suspend on the shared actor until
  the referenced image commits, matching spice-gtk's coroutine wait semantics.
  Wait count and retained decoded bytes are bounded; cancellation, dictionary
  clear, and already-evicted references terminate without leaking continuations.
- The expanded corpus covers 8,192- and 131,073-pixel same-image offsets
  (including the bit-17 very-long form), image distances 300 and 70,000
  (including two extension bytes), out-of-order gap closure, repeated
  window-head rollover, retained-edge references, and rejected references
  immediately beyond the advertised history. All four extreme offset/distance
  streams match spice-common output.
- A reverse-started 20-image dependency chain exercises suspended cross-image
  decode, actor reentrancy, ordered commit, and repeated dictionary eviction.
  Every dependent resolves to the source pixels, the retained window edge stays
  readable, and the immediately evicted history fails without another wait.
- Full and Mini header receive paths now publish explicit or implicit server
  serials to a session-wide cancellation-safe barrier. `INVAL_ALL_PIXMAPS`
  waits for every `(channel_type, channel_id, message_serial)` dependency before
  clearing the shared image cache.

### ZLIB GLZ slice

- Added strict `SPICE_IMAGE_TYPE_ZLIB_GLZ_RGB` (107) parsing for separate
  compressed `data_size` and exact uncompressed `glz_data_size` bounds.
- A small CZlib shim owns `z_stream` and requires `Z_STREAM_END`, exact output
  length, and full compressed-input consumption. Swift allocates only the
  prevalidated declared output size; oversized expansion requests are rejected
  before allocation.
- Inflated bytes feed the same Session-shared GLZ actor, so wrapped and
  unwrapped images share cross-image dictionary references and eviction state.
- The checked-in zlib/GLZ fixture matches spice-gtk 0.42.3's exported zlib and
  GLZ decoders. Every compressed prefix, trailing input, incorrect declared
  size, invalid zlib data, and over-limit expansion fail without changing the
  Surface or GLZ dictionary.

### MJPEG stream lifecycle slice

- Added strict current-wire decoding for Stream Create 122, Data 123, Clip 124,
  Destroy 125, Destroy All 126, and Data Sized 316. Stream IDs are restricted to
  the protocol's `[0, 64)` range; flags, codec enums, dimensions, clip counts,
  payload lengths, truncation, and trailing bytes are validated before state is
  changed.
- Display Link now advertises only the implemented stream capabilities:
  `SIZED_STREAM`, `MULTI_CODEC`, and `CODEC_MJPEG`. VP8/H.264/VP9/H.265 and
  stream reporting remain unadvertised.
- DisplayChannel owns at most 64 active stream records. Duplicate creation,
  unknown data/clip/destroy, capacity overflow, unsupported codecs, and invalid
  Surface destinations are typed protocol failures. RESET, Surface Destroy,
  explicit Destroy, and Destroy All release the relevant state.
- Every MJPEG packet is decoded by the existing exact TurboJPEG backend. Normal
  frames use the create-time source/destination geometry; sized frames carry
  their own frame dimensions and destination. TOP_DOWN and bottom-up streams,
  including a source shorter than the decode buffer, follow spice-common's row
  semantics.
- SurfaceStore performs nearest-neighbor stream scaling and all clip writes in
  one actor transaction. A malformed JPEG, invalid bitmap, bad geometry, or
  capacity failure leaves the previous Surface unchanged. Empty clips advance
  stream order without publishing a redundant frame.
- A session-wide multimedia clock is anchored from `MAIN_INIT.multimedia_time`
  against `ContinuousClock` and reset by strict Main message 106 decoding.
  Display channels share that clock. Timestamp comparison uses wrapping UInt32
  subtraction interpreted as Int32, so ordinary counter wraparound preserves
  early/late ordering.
- Frames are sequence-guarded across async decode. Due frames present
  immediately, future frames decode and then wait until their multimedia
  timestamp, and already-late MJPEG frames are dropped before TurboJPEG work.
  A frame that becomes late during decode/wait is also dropped before Surface
  mutation. Main clock resets are observed by active waits when they resume.
- Audio-driven latency correction remains part of Stage E Playback integration;
  this slice establishes the shared clock and video scheduling boundary only.
- Focused lifecycle coverage includes clip changes that affect only subsequent
  frames, 2x2 to 4x4 scaling, Data Sized overrides, bottom-up partial sources,
  failed-decode recovery, stream capacity, Destroy, and Destroy All.

Development and release products now statically link the checked-in arm64
artifacts for libjpeg-turbo, spice-common QUIC, usbredir, and libusb. The QUIC
slice no longer pulls in spice-gtk or GLib. `Scripts/verify-native-closure.sh`
rejects Homebrew, local build-tree, and other non-relocatable load paths.

## Stage D local closure

JPEG, LZ, QUIC, the shared image cache, GLZ/dictionary, ZLIB GLZ, and MJPEG
stream scheduling now satisfy the local Stage D gates: exact reference output,
bounded malformed-input handling, and transactional Surface mutation.

Live multi-Display/video interoperability remains part of the deferred QEMU
acceptance gate rather than evidence supplied by the local corpus.

## Stage E local closure

### Playback protocol and synchronization boundary

- Playback Link advertises only the implemented `VOLUME` and `LATENCY`
  capabilities. CELT 0.5.1 and Opus remain unadvertised and are rejected if a
  server sends them anyway.
- Added strict bounded wire decoding for DATA 101, MODE 102, START 103, STOP
  104, VOLUME 105, MUTE 106, and LATENCY 107. Packet payloads are capped at
  256 KiB; mode data, enums, channel counts, truncation, and trailing bytes are
  validated before channel state changes.
- The live QEMU gate exposed two schema mistakes hidden by the original local
  fixtures. Current spice-common defines `audio_data_mode` as `enum16`, and
  Playback START includes a trailing `uint32 time`; the decoder and Record MODE
  encoder now match that upstream wire layout, with exact-body regressions.
- PlaybackChannel implements the protocol ordering rules: supported MODE before
  START, DATA only while active, and STOP only from the active state. The local
  slice supports RAW signed 16-bit little-endian PCM from 8 to 192 kHz and at most
  eight channels. PCM packets must align to complete interleaved sample frames.
- `SpiceSession.playbackEvents` is a dedicated 32-entry newest-first bounded
  stream, separate from UI/session events, so slow audio consumption cannot
  create unbounded memory or duplicate PCM into the display event queue.
- `PLAYBACK_LATENCY` is surfaced as the server's minimum-buffer hint. It is not
  treated as measured device delay. A host sink reports its actual queued delay
  through `reportPlaybackDelay(milliseconds:)`; PlaybackChannel then anchors the
  shared multimedia clock to `last_packet_time - actual_delay`, matching the
  SPICE audio/video synchronization model.

### Bounded AVAudioEngine playback sink

- `SpiceAudioPlaybackSink` consumes the dedicated Playback stream and schedules
  interleaved RAW S16LE buffers on `AVAudioPlayerNode`. The source format is
  connected through `AVAudioEngine.mainMixerNode`, leaving conversion to the
  current output-device format to the engine.
- Queue state is bounded by a configurable duration (500 ms by default). It
  honors the server minimum-latency hint as the startup waterline, drops a
  packet that alone exceeds the whole budget, and on aggregate overflow flushes
  older scheduled audio in favor of the newest packet. Generation tags make
  callbacks from flushed buffers harmless.
- A drained player is stopped so its sample timeline is reset; the next packet
  rebuilds the configured startup buffer and restarts playback. Sink events
  expose starts, stops, overflows, oversized drops, underruns, and engine errors.
- Every 50 ms by default, the sink derives remaining frames from
  `AVAudioPlayerNode.playerTime` (falling back to queued frames before rendering)
  and reports that measured queue delay through `SpiceSession`. Mute and SPICE
  volume are applied at the player node; the current single-node backend uses
  the average for a multi-channel volume vector rather than a per-channel gain
  matrix.
- `SpiceAudioPlaybackSink.statistics()` exposes monotonic scheduled packet and
  frame counts for non-GUI acceptance without copying PCM into a second stream
  consumer.

The bounded queue, stale-callback rejection, underrun recovery, delay math, and
exact PCM buffer population are covered deterministically. Playback is also
live-closed through the independent Rocky x86_64 audio fixture: QEMU 8.2.2 and
spice-server 0.15.1 exposed an ICH9 HDA duplex device, the guest generated an
880 Hz S16LE stream, and SwiftSpice observed RAW 48 kHz stereo START,
`mute=false`, then scheduled a 480-frame packet in AVAudioEngine. Evidence is in
the remote run `audio-live/logs/20260801T025001Z`. Human-audible output and
device route changes still require operator/hardware acceptance.

### Record protocol and bounded AVAudioEngine capture source

- Record Channel strictly decodes server START 101, STOP 102, VOLUME 103, and
  MUTE 104. RAW S16LE streams are limited to 1 to 8 channels and 8 to 192 kHz;
  duplicate START, STOP while inactive, DATA while inactive, and incomplete
  interleaved PCM frames fail the channel.
- Client capture traffic enforces the protocol sequence RAW MODE 102,
  START_MARK 103, then timestamped DATA 101. Mode/start marking is tied to a
  server-started stream and cannot be repeated or bypassed.
- `SpiceSession.recordEvents` is a dedicated 32-entry oldest-first control
  stream. Overflow is fatal instead of silently losing START/STOP state, while
  PCM travels directly from the capture sender to RecordChannel and is capped
  at 256 KiB per packet.
- `SpiceAudioCaptureSource` installs a tap only for an active server-requested
  stream, converts the default macOS input format to the requested interleaved
  S16LE format, and hands packets to async transport through a mutex-protected
  duration-bounded queue (500 ms by default). Aggregate overflow discards the
  oldest packets to bound latency and reports the dropped duration.
- Core Audio callbacks do not create one Task per buffer. A newest-one signal
  wakes one async drain, so callback rate cannot create unbounded task or PCM
  accumulation. Conversion failures and channel failures stop the active tap
  and are published through source events.
- Record volume/mute messages are decoded and surfaced, but their capability is
  not advertised and software input gain is not yet applied. CELT/Opus are also
  unadvertised. An embedding app must provide `NSMicrophoneUsageDescription`,
  user-visible capture state, and consent handling.

Wire/state/queue behavior is covered locally. The client-to-guest Record wire is
also live-closed with a deterministic non-microphone source: SwiftSpice received
RAW 48 kHz stereo START, sent 144,000 frames using 16-bit MODE/START_MARK/DATA,
and the Alpine guest completed a 2,880,000-byte `arecord` artifact with SHA-256
`312d8ac05afe6a46da9aac84169a3d022ceca4e9dacd7280f2c1cecc7306b4e5`.
That differs from an all-zero artifact of the same size. Evidence is in remote
run `audio-live/logs/20260801T025212Z`. Actual microphone permission and input
route conversion remain `pending_hardware`; the synthetic gate does not claim
physical microphone coverage.

### Main/Agent transport and UTF-8 clipboard

- Main Link now advertises only `SPICE_MAIN_CAP_AGENT_CONNECTED_TOKENS` from the
  implemented Main capability set. Main Init and both connected notification
  variants seed explicit Agent connection/token state; duplicate or
  out-of-order connect, disconnect, token, and data messages fail the channel.
- `AGENT_START` is the first client Agent message and grants the server an
  eight-packet receive window. Every accepted server packet consumes and then
  replenishes one token. Client sends are preflighted against their complete
  fragment count, so insufficient tokens cannot produce a partial logical
  message.
- Added bounded VDAgent stream framing: 20-byte little-endian headers, 2048-byte
  SPICE packet fragments, 16 MiB logical-data ceiling, headers/payloads split at
  arbitrary packet boundaries, multiple logical messages per packet, and
  preservation of unknown protocol/type values. Bootstrap queues at most 64
  Agent events and 16 MiB of Agent payload before Channels List arrives.
- `SpiceSession.agentEvents` is a dedicated 64-entry oldest-first stream. Agent
  control/data events never share the frame-coalescing path; if its bounded
  consumer queue fills, the session fails instead of silently losing clipboard
  protocol state.
- The framing work uncovered and fixed `ByteReader` bulk reads against a
  non-zero-index `Data` slice. A regression test now covers that path.
- VDAgent capability negotiation advertises clipboard, clipboard-by-demand,
  monitor integration, and file-transfer detailed-error decoding. The state
  machine implements symmetric UTF-8
  GRAB/REQUEST/DATA/RELEASE ownership, rejects unsolicited or invalid UTF-8
  payloads, bounds text to the 16 MiB Agent envelope minus its four-byte type,
  suppresses pasteboard echo, and reoffers unchanged local text after reconnect.
- `SpiceAgentManager` consumes the dedicated Agent event stream, retries an
  announcement held back by exhausted client tokens, polls the general macOS
  pasteboard at a configurable 250 ms default, and provides `publish(_:)` for an
  immediate path. All `NSPasteboard` access is isolated in a small `@MainActor`
  bridge, and pasteboard write refusal is surfaced as a failure event.
- Main Init's initial Agent-connected state is now published into
  `SpiceSession.agentEvents`, so a manager started immediately after `connect`
  does not depend on a later connected notification.
- Dynamic resolution now encodes the exact single-monitor
  `VD_AGENT_MONITORS_CONFIG` layout (height precedes width on wire), advertises
  MONITORS_CONFIG and REPLY without claiming sparse/position support, and
  strictly decodes the matching `VD_AGENT_REPLY`. Legacy peers retain the
  protocol-defined baseline monitor/reply capabilities until they explicitly
  announce otherwise.
- `requestResolution(width:height:)` validates UInt32 dimensions, serializes
  requests behind Agent tokens, keeps only the newest resize while a reply is
  pending, and requeues the active request across Agent reconnect. Its event
  stream distinguishes queued, sent, acknowledged, rejected, unsupported, and
  transport/protocol failures.
- Multi-monitor requests now use explicit IDs and signed positions. The Agent
  manager validates unique IDs and wire ranges, inserts 0x0 placeholders for
  missing/disabled IDs only when sparse configuration is negotiated, and sets
  USE_POS only when the peer advertises monitor-position support. Continuous
  layout changes still coalesce to the latest complete configuration.
- Display Link advertises `SPICE_DISPLAY_CAP_MONITORS_CONFIG`. Message 317 is
  decoded as the authoritative `count/max_allowed/QXLHead[]` result with a
  256-head bound, exact body sizing, unique IDs, nonzero geometry, and checked
  coordinate extents. Empty notifications are acknowledged but do not replace
  the last useful layout.
- `SpiceSessionEvent.displayConfiguration` publishes the actual guest monitors,
  surface IDs, positions, dimensions, flags, maximum supported heads, and the
  originating Display Channel ID. This preserves the Linux multi-head/single-
  channel versus Windows multi-device/channel distinction.

### Bounded, explicitly authorized file transfer

- Added strict codecs for `VD_AGENT_FILE_XFER_START`, `STATUS`, and `DATA`,
  including all status values plus packed GLib-I/O and free-space details.
  Metadata contains only a validated basename and UInt64 byte size; separators,
  control characters, dot paths, leading/trailing whitespace, oversized names,
  and inconsistent chunk lengths are rejected.
- `SpiceAgentManager.sendFile(at:name:)` is the sole initiation path. It accepts
  one regular file selected by the application, never scans directories or
  reacts to clipboard/drag state automatically, and waits for an explicit peer
  capability announcement that does not contain `FILE_XFER_DISABLED`.
- A transfer sends START, waits for `CAN_SEND_DATA`, reads at most one bounded
  chunk off the manager actor, then sends DATA. Chunks are capped at 16,000
  bytes so a complete Agent message fits the common eight-token window; token
  exhaustion sends no partial message and is retried by the existing Agent
  work loop.
- At most four transfers and one pending chunk per transfer are retained by
  default. Source size defaults to an 8 GiB policy ceiling. A file truncated or
  made unreadable during transfer produces a client ERROR status rather than
  leaving a guest transfer ID hanging.
- Completion requires a guest SUCCESS after all declared bytes are sent.
  Application cancellation before START is purely local; after START it sends
  CANCELLED. Disconnect fails active transfers. Detailed status, progress, and
  terminal results use a dedicated bounded `fileTransferEvents` stream.
- Standard VDAgent file transfer is host-to-guest. Unsolicited guest START/DATA
  is rejected as a protocol error; this implementation never derives or writes
  a host path from guest data. Security-scoped URL acquisition and release stay
  under embedding-application control.

Clipboard integration remains UTF-8 text only. Images, clipboard
selection/serial extensions, and a committed-text paste-keystroke workflow are
not implemented. File transfer is a separate explicit host-to-guest path.
Inputs remains physical PC scan-code transport; VDAgent UTF-8 clipboard is a
separate data path and is not guest IME composition synchronization. Automatic
general-pasteboard synchronization is privacy-sensitive and must be exposed as
such by an embedding application.

## Stage F advanced-video groundwork

- Added a bounded Annex-B parser for H.264 and H.265. It accepts three- and
  four-byte start codes, validates forbidden/header fields, caps encoded bytes,
  NAL size, and NAL count, and rejects empty/trailing units.
- AVC SPS/PPS/SPS-extension and HEVC VPS/SPS/PPS are separated from picture
  data. Remaining units are converted to CoreMedia's four-byte big-endian
  length-prefixed sample representation. Picture and random-access NALs are
  classified without parsing unbounded Exp-Golomb payloads.
- Added the isolated `SpiceVideoToolbox` target. Its actor accumulates parameter
  sets, creates the matching CoreMedia format description, and owns a
  synchronous `VTDecompressionSession`. It requests Metal-compatible,
  IOSurface-backed NV12 and emits a package-only frame that retains the
  immutable `CVPixelBuffer`. Every plane, stride, matrix, and range is bounded;
  `copyBGRA()` is a one-time lazy cached fallback. Hardware decode is allowed
  but not required, and aggregate diagnostics record hardware, software, and
  query-failed session selection after creation. Parameter-set replacement
  creates and validates the new session before atomically swapping it with the
  old one; a failed creation remains marked for retry on the next frame.
- DisplayChannel now owns an advanced decoder per H.264/H.265 stream, routes
  decoded output first through the package-only native Metal compositor and
  then, when required, through the existing BGRA clip/scale transaction,
  and closes decoder sessions on stream/surface destruction, RESET, destroy-all,
  or channel close. Already-late inter-frame video is still submitted so codec
  reference state and in-band parameter sets advance, but its decoded image is
  intentionally not committed. Frame-local mapping/format errors fall back for
  that frame; pipeline or command-execution failure permanently disables Metal
  for the current stream generation. Every advanced CPU fallback is counted.
- Added reproducible FFmpeg 8.1.2 software reference fixtures for H.264 High,
  H.264 Baseline, and H.265 Main at 128x128. The Baseline stream changes SPS/PPS
  on an existing decoder and proves session replacement. Real VideoToolbox
  output matches independent FFmpeg software-decoded BGRA with exact geometry
  and alpha and a maximum RGB delta of four from YUV conversion rounding.
- The safe-default Display Link remains exactly `SIZED_STREAM`,
  `MONITORS_CONFIG`, `MULTI_CODEC`, and `CODEC_MJPEG` (`0x303`). An explicit
  endpoint policy may add either `CODEC_H264` (`0xb03`) or `CODEC_H265`
  (`0x4303`). The local encoded/decode backend corpus gate is closed for both
  codecs.
- A Rocky x86_64 live probe confirmed that Ubuntu's spice-server 0.15.1 accepts
  an H.264 preference and creates real `x264enc` streams. Its unconstrained
  `videoconvert`, however, negotiates Y444 and emits H.264 High 4:4:4, which
  macOS VideoToolbox rejects with status `-8969`. The experimental capability
  advertisement is therefore not the default. A separate guest stream-device
  probe then supplied deterministic 1280x720 yuv420p H.264 Constrained Baseline
  through the unmodified server. With explicit H.264 policy and the stream
  active, SwiftSpice published 360 aggregate Display frames in eight seconds
  without a decode/session failure; the server observed
  `h264=1 streaming=1`. The default-policy negative gate observed
  `h264=0 streaming=0`. The same fixture supplied deterministic 1280x720
  yuv420p H.265 Main. With explicit H.265 policy, SwiftSpice again published
  360 aggregate Display frames in eight seconds without a decode/session
  failure; the server observed `h265=1 selected=h265 streaming=1`. Its default
  negative gate observed `h264=0 h265=0 selected=none streaming=0`. The
  loopback-only reproduction fixture is under `Integration/RemoteRocky/Video`.
  These retained runs prove protocol advertisement and VideoToolbox decode;
  they predate, and therefore do not prove, the revisioned IOSurface/Metal
  composition path below.
- Added an isolated `SpiceIOSurface` ownership target and a default
  triple-buffer frame pool keyed by geometry and 32-bit BGRA pixel format.
  Allocation is bounded by frame count and bytes; idle mismatched entries may
  be evicted, while exhaustion by live readers immediately returns the existing
  immutable `Data` frame instead of blocking the Display receive loop.
- Each published frame holds an immutable IOSurface read lease. The pool cannot
  recycle that surface until the last copied/coalesced/presented frame releases
  it. `SpiceFrame` exposes IOSurface identity and geometry while preserving
  immutable packed-BGRA semantics and existing semantic equality; its `Data`
  readback is generated on first CPU access and then cached.
- Real IOSurface allocation, lock/copy/unlock, byte-exact readback, exhaustion
  fallback, and post-release reuse are covered by local tests.
- The current Apple Silicon backing is a per-Surface revision ring, enabled only
  when the device reports unified memory, Apple GPU family 7 or newer, and a
  real IOSurface texture probe succeeds. Every Surface has at most three slots,
  including retired slots still held by old frames, under one process-wide
  256 MiB IOSurface allocation budget shared with the legacy snapshot pool.
- A published canonical slot is immutable while any frame or GPU presentation
  lease is live. After all leases release, validated CPU-only damage may reuse
  it in place; native-video and other fallible GPU writes always use a distinct
  candidate. Lagging candidates catch up from bounded revision damage history
  with at most 64 losslessly coalesced rectangles. A cheap rectangle-area upper
  bound avoids unnecessary union work; exact sweep-line union coverage reaches
  the 50-percent threshold before the journal becomes a full upload.
  Three live consumer leases cause an immediate Data snapshot fallback rather
  than a Display wait; cached legacy slots are purged before pressure demotes
  the revisioned path. Resize, store close, and same-ID recreation retire slots
  without invalidating old frames. Store close first enters a terminal state,
  rejects new operations, drains every in-flight per-Surface tail, and lets
  concurrent close callers observe the same completed teardown.
- The session-wide CPU budget counts every live canonical Surface across all
  Display channels. A Data fallback snapshot makes an independent packed-BGRA
  copy at the publication boundary, so a caller retaining only `pixels` cannot
  participate in a later canonical Surface COW. Frame backlog remains bounded
  separately by the session mailbox.
- `SpiceMetalCompositor` maps NV12 Y as `r8Unorm` and UV as `rg8Unorm`; one
  command encoder applies BT.601/709, video/full range, top/bottom orientation,
  nearest scaling, all clips, and writes the candidate IOSurface. The source
  pixel buffer and texture wrappers live through command completion, and a
  candidate becomes canonical only after successful completion. Unknown color
  matrices and odd NV12 geometry use the CPU reference path.
- `DisplayFramePublisher` uses metadata-only descriptors and exact
  lifecycle/revision snapshots. `SpiceFrame.pixels` preserves immutable
  packed-BGRA semantics through a shared one-time lazy cache; a normal Metal
  viewer does not materialize it.
- Aggregate diagnostics cover damage and copy bytes, CPU materialization, pool
  exhaustion and leases, GPU copies/errors, native/fallback video, publisher
  suppression, and actual VideoToolbox decoder selection. There is no per-frame
  telemetry log. `spice-probe --require-native-video` turns the zero-BGRA and
  zero-GPU-error expectations into a live gate. Fault-injection regressions
  prove failed VT session creation retries and a Metal command error disables
  only the current stream generation before CPU fallback.
- The SwiftPM `CompileMetalShaders` build-tool plugin produces the resource
  `.metallib`. Apple Silicon app staging installs its bundle under
  `Contents/Resources`, and the closure verifier requires exactly one arm64
  executable slice, macOS 26 minimum, the shader entry point, signing, and no
  absolute build-machine/Homebrew paths.
- `SpiceDesktopView` keeps its existing narrow `NSViewRepresentable` and AppKit
  responder boundary, but its private framebuffer view now owns an on-demand
  `MTKView` child. IOSurface-backed BGRA frames become Metal textures and are
  blitted into same-sized drawables; CPU-only frames continue through the
  existing AppKit/CGImage implementation.
- The command-buffer completion callback retains the source `SpiceFrame`, so an
  in-flight GPU read cannot race frame-pool recycling. Cursor composition stays
  in a transparent AppKit overlay and therefore behaves identically on Metal
  and CPU fallback paths.
- IOSurface now chooses its aligned row stride rather than inheriting the packed
  CPU stride. A real Metal test maps the IOSurface, performs the GPU blit, and
  reads back byte-exact BGRA. CPU-only rejection and the complete existing suite
  are also covered.
- Added the `spice-viewer` SwiftPM GUI executable and a project-local
  `Scripts/build-and-run.sh` that stages a real `SpiceViewer.app`, supports
  run/debug/log/telemetry/verify modes, and backs the Codex `Run` action.
- The validation host drives synthetic 640×360 BGRA SurfaceStore frames with an
  absolute-deadline 30 fps schedule. Window-level inspection confirmed animated
  Metal output, aspect-fit presentation, and a measured 29.3 fps submission
  rate. Unified logging confirmed one host-start event and one transition to
  `Metal IOSurface` without noisy per-frame logging.
- Promoted `spice-viewer` to a session-driven macOS viewer while retaining the
  synthetic mode as `Offline Validation`. `Remote Session` exposes validated
  host/port input, TCP, system-trust TLS, and explicitly unsafe test TLS, plus a
  non-persisted ticket password and connection/error state.
- The viewer owns one supervised session-event task and consumes frame, surface,
  cursor, mouse-mode, failure, and disconnect events on the main presentation
  boundary. Input enters one bounded 256-event FIFO and one sequential sender
  task rather than creating a task per key or pointer event.
- Real-window inspection covered mode switching, the session form, immediate
  connection cancellation, local validation errors, and continued IOSurface
  Metal presentation near 30 fps. The endpoint/TLS mapping has focused tests;
  the complete local suite passed 194 tests in 45 suites at that slice.
- Added cancellable connection lifecycle hardening. Each attempt has a 10-second
  deadline, and optional reconnect makes at most five retries with bounded
  1/2/4/8/16-second backoff. Disconnect, mode changes, and window closure cancel
  both active establishment and backoff immediately.
- Fixed `NetworkSpiceTransport` establishment cancellation at the transport
  boundary. It now starts TCP/TLS with a non-suspending empty idempotent send,
  observes channel state, and terminates the wait through its AsyncStream when
  the caller task is cancelled; it does not attempt a second blocking graceful
  close on an unestablished channel.
- Endpoint profiles persist only normalized name, host, port, and TLS mode.
  Passwords remain transient within the active connection lifecycle and are
  absent from both profile JSON and unified logs.
- Added bounded unified telemetry in `Profiles`, `Navigation`, and `Session`
  categories. Live log inspection confirmed profile load, mode selection,
  connection attempts, timeout, retry scheduling, and user cancellation without
  endpoint or credential disclosure.
- The viewer now discovers Playback channel 0 after session bootstrap and only
  then attaches `SpiceAudioPlaybackSink`. Its connected status bar surfaces
  format/mute state plus bounded resynchronization, oversized-drop, underrun,
  and dropped-duration counters. Sink failures enter the same visible bounded
  state instead of being hidden in a detached task.
- Disconnect, retry, mode changes, and window closure cancel the playback event
  supervisor and stop the sink before releasing the session. A real disconnected
  app launch produced no Playback attachment log, confirming that AVAudioEngine
  is not initialized before a Playback channel exists. That slice's
  warnings-as-errors gate passed 199 tests in 47 suites.
- The viewer now treats Record availability and microphone consent as separate
  states. Discovering Record channel 0 exposes `Mic Off` but does not query
  permission or construct `SpiceAudioCaptureSource`; Enable Mic is the only path
  that requests access and attaches the source. Permission wait can be cancelled,
  and an independent request generation rejects late authorization results after
  cancellation, disconnect, retry, or mode changes.
- Record status exposes permission denial/restriction, server start/stop, format,
  mute, capture failure, overflow count, and dropped duration. Disconnection
  stops the source before releasing the session and resets to per-session opt-in.
  The staged app contains `NSMicrophoneUsageDescription`; launch logs contain no
  permission request or Record attachment. That slice's warnings-as-errors gate
  passed 201 tests in 48 suites.
- The viewer now exposes Agent UTF-8 clipboard as a per-session explicit opt-in.
  Before opt-in it drains the bounded `agentEvents` stream so a long-running
  session cannot fail merely because Agent control traffic has no consumer, but
  the drain discards events and never calls `SpicePasteboardBridge`. Enabling
  clipboard waits for that drain to terminate before handing the single stream
  to `SpiceAgentManager`; disabling performs the inverse handoff.
- Clipboard status surfaces negotiation readiness, host/guest ownership using
  byte counts only, oversized local rejects, and failures. It never retains or
  logs clipboard text. The UI and diagnostics explicitly identify this as
  VDAgent UTF-8 data transfer rather than Inputs scan codes or guest IME state.
  Disconnect, retry, and mode changes stop the manager before the session. A
  staged-app launch emitted no Clipboard telemetry or manager attachment. That
  slice's warnings-as-errors gate passed 203 tests in 49 suites.
- Refactored the viewer to keep one shared `SpiceAgentManager` for Agent control,
  monitor, clipboard, and file-transfer work. Its pasteboard policy is now
  mutable and protocol-visible: disabled mode advertises monitor/reply/sparse-
  monitor/file-transfer detailed-error support without clipboard/by-demand,
  ignores stale guest clipboard commands, and gates `synchronizePasteboard()`
  and `publish(_:)` before the AppKit bridge. Enabling/disabling reannounces the
  matching capabilities without replacing the Agent event consumer.
- Added explicitly authorized host-to-guest file selection through one narrow
  `NSOpenPanel` bridge. The panel accepts one regular file; the manager opens it
  while its security-scoped access is active, then owns the bounded reader.
  Viewer state retains at most eight entries and exposes queued, guest approval,
  progress, completion, failure, and cancellation. File names are visible in
  the user's menu but logs contain only transfer IDs and byte counts.
- A file-transfer menu provides Send File and per-active-transfer cancellation.
  It is available independently of clipboard opt-in and never changes the
  pasteboard policy. The staged app builds and launches without implicit
  Clipboard or file-transfer telemetry. That slice's warnings-as-errors gate
  passed 206 tests in 50 suites.
- Added a dedicated monitor popover backed by the shared Agent manager. It
  groups monitor IDs, surfaces, positions, and dimensions by Display Channel ID,
  retains the last useful inventory across empty notifications, and exposes a
  validated single-monitor width/height request without enabling clipboard.
- Resolution lifecycle state distinguishes queued, sent, acknowledged,
  rejected, unsupported, failed, and applied. Agent acknowledgement never
  mutates the inventory; only a subsequent matching Display Channel notification
  marks the request applied. Focused state tests cover this authority boundary.
  The staged viewer builds and launches cleanly, and the current
  warnings-as-errors gate passed 209 tests in 51 suites.
- Added a complete multi-monitor draft editor with add/remove rows, explicit
  0...255 IDs, positive UInt32 dimensions, and signed Int32 positions. A new
  Agent support stream reports baseline versus explicit monitor, sparse-ID, and
  position capabilities; the editor gates submission locally while the manager
  retains its wire-level validation.
- A single Display Channel draft preserves its monitor IDs. Multiple Display
  Channels are flattened deterministically and assigned sequential request IDs
  with an explicit warning because channel-local IDs cannot be assumed to map
  losslessly to VDAgent request indexes. Multi-monitor requests are marked
  applied only after a matching authoritative inventory. The current
  warnings-as-errors gate passes 214 tests in 52 suites.
- Added strict Main migration decoding for BEGIN, BEGIN_SEAMLESS, CANCEL,
  SWITCH_HOST, END, and destination seamless ACK/NACK, plus exact client
  CONNECTED, CONNECT_ERROR, END, DST_DO_SEAMLESS, and CONNECTED_SEAMLESS reply
  encoding. Destination host and certificate-subject C strings are bounded to
  4096 bytes, require final NUL without embedded NUL, require valid UTF-8, and
  reject destinations with no usable port.
- Added a generation-tagged migration handoff coordinator. A newer BEGIN first
  cancels the old preparation, late completion is ignored, CANCEL releases both
  preparing and prepared targets, and END is a protocol violation until a target
  is ready. Public session events expose preparing, ready, cancelled, committing,
  switching, completed, and failed phases without logging destination details.
- The session owns and cancels the handoff task across replacement, disconnect,
  and receive failure. Connection bootstrap now produces a locally owned
  prepared session without mutating the active Main/child Channel set. Migration
  targets correctly reuse the source session ID and source Channel inventory;
  they do not wait for a second MAIN_INIT/CHANNELS_LIST. A target becomes ready
  only after every source child Channel is authenticated and constructed;
  preparation failure or cancellation closes only those target transports and
  leaves source supervision running.
- Semi-seamless END first writes client MIGRATE_END to the prepared target, then
  atomically replaces the Main/child Channel set and starts its supervision
  before closing the source set. A dual-session fixture proves that subsequent
  Main events and Inputs writes use the target while source Inputs stay closed.
  Separate fixtures prove failed and cancelled preparation rollback. Existing
  TLS sessions cannot be downgraded to a plaintext migration port, and an
  unverified certificate subject is rejected. A target-only Main Link advertises
  the requested migration capabilities; when the target server confirms seamless
  support, the client sends DST_DO_SEAMLESS with the exact source version and
  strictly accepts only ACK/NACK before reporting CONNECTED_SEAMLESS or falling
  back to CONNECTED. Ordinary source Main Links now advertise both semi-seamless
  and seamless migration after state-preserving connection rebinding closed the
  remaining local handoff boundary.
  Common-Channel migration is now implemented as a strict connection-level
  boundary: MIGRATE accepts only NEED_FLUSH/NEED_DATA_TRANSFER, blocks later
  ordinary writes immediately, sends FLUSH_MARK before reading optional opaque
  MIGRATE_DATA, and rejects missing, unsolicited, or misordered state packets.
  The session waits for Main and every source child Channel before forwarding
  each opaque state body to its matching target connection and atomically
  adopting the target set. A partial flush followed by CANCEL reopens only the
  paused source connections and keeps the source usable. Prepared migration
  actors are no longer adopted: after an exact inventory check, authenticated
  target connections are rebound onto the existing Main, Display, Cursor,
  Inputs, Playback, Record, and passive actors. Source connections are then
  closed, preserving Display surfaces/image cache, Cursor cache/snapshot, Inputs
  button state, Main Agent token/decoder state, active audio state, and the shared
  multimedia clock. `SWITCH_HOST` intentionally retains full-session replacement.
  The warnings-as-errors gate passes 242 tests in 55 suites.

## Stage F peripheral-channel local closure

- Smartcard implements strict VSCARD 0.0.2 framing for reader/card/APDU/error/
  flush traffic, bounded payloads, a serialized control queue, migration-safe
  connection rebinding, and Session supervision. Reader and card ownership is
  application-explicit; the library never enumerates or opens host smartcards.
- USB redirection uses the generic SpiceVMC Channel plus an exact
  `libusbredirhost`/libusb C backend. It bounds every guest/host packet and pump
  interval, applies the guest filter, and requires an application-selected
  bus/address before opening a device. A raw packet bridge remains available to
  applications that own another backend.
- WebDAV strictly decodes Port initialization/events and incrementally
  demultiplexes bounded client streams. The optional native DAV class-1 server
  requires an explicit root, defaults to read-only, supports PROPFIND/GET/HEAD,
  and enables PUT/MKCOL/DELETE/file COPY/MOVE only under an explicit read-write
  policy. Canonical containment and symlink checks prevent root escape. The raw
  request/response bridge remains available when no native backend is attached.
- Session owns the optional USB/WebDAV backends, cancels pumps and clears client
  state on disconnect/failure, and preserves state across seamless connection
  rebinding. Focused tests prove that no card, USB device, or filesystem root is
  selected implicitly.
- Guest WebDAV mounting is live-closed on the independent Rocky x86_64 fixture.
  SwiftSpice authenticated through an SSH tunnel to QEMU 8.2.2 and
  spice-server 0.15.1, attached an explicit read-only root over
  `org.spice-space.webdav.0`, and an Alpine 3.22 guest running spice-webdavd
  3.0-r4 and davfs2 1.6.1-r2 completed both a direct HTTP GET and a davfs2
  mount/read. The guest observed 31 bytes with SHA-256
  `492d1e4f0bc7e1ce3ae8d06e597d4197dbe5029ff75956f720938f940499b297`.
  The reproducible, loopback-only fixture and lifecycle commands are under
  `Integration/RemoteRocky/WebDAV`; run evidence is stored remotely per run.

## Apple Silicon optimization acceptance status

- The production `.automatic` backend keeps ordinary SPICE 2D commands on the
  CPU while using revisioned IOSurface publication when supported. The
  IOSurface-canonical Metal 2D batch is retained only behind the explicit
  experimental `.metal` backend. Fill, decoded bitmap copy, overlap-safe
  COPY_BITS, and cross-Surface copy share one command buffer until snapshot or
  the bounded 512-command/16-MiB threshold. Canonical output becomes visible
  only after GPU completion; an injected failure replays the complete batch on
  the CPU.
- Focused M4 tests prove a four-command batch uses one command buffer and
  matches the CPU renderer byte-for-byte, preserves ARGB cross-Surface copy
  without CPU readback, and recovers from an injected GPU failure. Probe JSON
  reports Metal 2D command buffers, commands, upload/blit bytes, and completed
  GPU time. These are local correctness results, not a live performance pass.
- Recording Metal batches now have an explicit idempotent cancellation path,
  with close, surface destroy, stale transaction, encode failure, and injected
  pre-commit failure all ending an active encoder before release. Focused close
  and destroy tests no longer trigger Metal's `endEncoding` abort.
- CPU-only rendering bypasses Metal enqueue and empty-flush calls. Probe
  diagnostics now split CPU opcode counts/timing, revision GPU clones, batch
  seed CPU/GPU copies, snapshot catch-up copies, per-Metal-opcode counts, and
  upload-buffer allocation/reuse. A dedicated Metal-to-CPU fallback counter
  covers every supported opcode that takes a CPU route, including all commands
  replayed after a failed Metal batch. Live Metal evidence rejects any such
  fallback or supported CPU opcode activity. Bitmap uploads use a power-of-two
  persistent MTLBuffer pool across completed batches; hard resident-byte and
  buffer-class caps plus memory-pressure purge remain required before
  production enablement.
- In-place mutation of the current IOSurface was not enabled: it would break
  the batch's rollback guarantee when GPU execution fails. Snapshot-driven
  commits also remain at the 16-ms publication boundary; reducing them would
  trade benchmark CPU for visible frame latency and needs a separate policy.
- A 2026-08-03 host rerun at PR #4 head `d68a8ec` collected all requested
  10x30-second CPU/GLib and Metal/GLib samples at 1280x720 and 3840x2160. All
  four formal batches remained invalid because display activity stopped in late
  samples. Activity-valid diagnostics failed CPU/frame in all
  configurations: 1.313759 (720p CPU, 8 pairs), 2.174098 (720p Metal, 7 pairs),
  1.107982 (4K CPU, 8 pairs), and 1.811612 (4K Metal, 8 pairs). The 4K Metal
  RSS ratio was 1.255131. Every Metal process exited zero and recorded completed
  commands with zero CPU execution of the four supported Metal 2D opcodes,
  dedicated fallback, CPU materialization, GPU error, and pool exhaustion.
  Scaled copy and native-video counters were also zero in every activity-valid
  sample; the actual command mix was bitmap copy, so snapshot catch-up cannot be
  attributed to MJPEG scaling in this workload. Median Metal batch-seed GPU
  copies were 5.65 GB at 720p and 53.91 GB at 4K; snapshot catch-up CPU copies
  were 2.44 GB and 30.34 GB. The seed totals exactly match one full-surface
  clone per command buffer, so canonical cloning, snapshot catch-up, and
  publication-driven flush frequency remain higher-priority than shader tuning.
  The reported Metal GPU time covers draw batches but excludes the separate
  seed blit. A sanitized nine-set evidence archive with exact tested tools and
  per-file checksums is retained under `Benchmarks/Results/2026-08-03/`; the
  full evidence disposition is in `Benchmarks/RESULTS_ROCKY8_2026-08-03.md`.
- `spice-probe --renderer automatic|cpu|cpu-iosurface|metal` provides explicit
  engine/backing configurations. `automatic` and `cpu-iosurface` use CPU 2D
  with automatic and required revisioned backing respectively; `cpu` is the
  historical Data-backed mode; `metal` is experimental and requires revisioned
  backing. The live
  runner now requires full-window activity evidence, successful process exit,
  and a stable guest boot epoch within each pair. A 2026-08-02 alternating
  10x30-second CPU/Metal collection covered 1280x720 and 3840x2160, but its
  formal verdict was rejected when the old reset fixture became static in late
  pairs. The first eight contiguous valid pairs are retained only as diagnostic
  prefixes: their CPU-per-frame ratios were 1.468515 (720p CPU), 1.944140
  (720p Metal), 1.375421 (4K CPU), and 1.534300 (4K Metal), all above the 1.10
  limit. The 4K Metal RSS ratio was also 1.256189, above 1.15. These failures
  identify current optimization work; they are not a substitute for a valid
  ten-pair confidence interval.
- Those retained CPU and Metal prefixes are not a direct Swift CPU-versus-Metal
  A/B: `cpu` used Data backing while `metal` used revisioned IOSurface backing,
  and the variants came from different batches. Future Metal benefit claims
  must pair `cpu-iosurface` against `metal` while also retaining `cpu` as the
  historical Swift-versus-GLib configuration. A dedicated direct runner and
  analyzer now alternate `cpu-iosurface` with `metal`, require matching start
  and end boot IDs plus one batch-wide guest epoch/codec/resolution, reject
  Metal scaled-copy and cpu-iosurface materialization, verify frame bytes
  against the declared resolution, and compute `metal / cpu-iosurface` pairwise
  ratios. The tooling
  has not yet been run against the live fixture, so it provides no Metal-benefit
  result yet; two separate Swift-versus-GLib directories remain insufficient.
- All 20 Metal processes in that collection exited zero, recorded zero GPU
  errors and zero CPU materializations in valid samples, and avoided the former
  encoder-lifecycle abort. Median 4K Metal diagnostics nevertheless recorded
  53.25 GB of batch-seed GPU copies and 29.56 GB of snapshot catch-up CPU copies
  per 30-second sample, making copy and publication policy higher-priority
  performance targets than shader tuning.
- The guest workload resets the existing animation generator with `SIGUSR1`
  instead of intentionally creating a new xterm per sample. The 2026-08-02
  fixed-fixture 10x5-second stress produced 20/20 activity-valid 720p samples
  and 19/20 at 4K. A fresh 2026-08-03 4K stress reached 20/20, but the longer
  CPU and Metal batches still became static; even `control.sh start` did not
  restore sustained activity after degradation. Short stress alone is
  therefore insufficient. The fixture now emits a generation, completed-frame
  ID, monotonic uptime, PID, and Linux boot ID about once per second; each round
  preserves those records separately, and a host wrapper exposes the guest boot
  ID to the benchmark runners. This localizes future generator stalls but does
  not count X11 Present/Damage. The next formal run is gated on deploying and
  exercising this telemetry, replacing or repairing the xterm renderer,
  full-duration activity preflight, a fresh `cpu` versus GLib reference, and a
  live direct `cpu-iosurface` versus `metal` collection.
- The previous 2026-08-01 current-tree five-second Rocky smoke used an arm64
  Release probe containing the uncommitted publisher revision-race fixes.
  SwiftSpice published 52.0 fps versus 49.2 fps for spice-client-glib2, a
  passing 1.056911
  ratio. Ready-frame (0.772646), p95 (0.673903), and RSS (0.658301) also passed.
  Publisher stale snapshots fell from the earlier 48/261 (18.39%) sample to
  0/265. CPU per frame remained the blocking metric at 1.451688 ms versus
  1.206650 ms, a failing 1.203073 ratio. CPU materialization, pool exhaustion,
  GPU copy, GPU errors, and pending evictions were zero. Because the smoke still
  failed, the formal ten alternating pairs of 30 seconds were not started.
  Retained evidence, the tested probe hash, and exact collection paths are
  documented in `Benchmarks/RESULTS_ROCKY8_2026-08-01.md`.
- On the current M4 Pro host, the strict final-tree Rocky native-video gate
  passed both codecs. H.264 decoded 233 frames with 14 native Metal
  compositions; H.265 decoded 233 with 28 native compositions. Both selected a
  hardware VideoToolbox session and reported zero VT/general BGRA materialization,
  fallback, GPU error, stream-generation disable, and pool exhaustion. The
  server independently reported `selected=h264 streaming=1` and
  `selected=h265 streaming=1`.
- SwiftSpice now has an explicit Apple Silicon-only product contract: non-arm64
  compilation is rejected, native dependencies contain only arm64, release
  staging builds only arm64, and the closure verifier rejects any extra slice.
  The final `--package` gate passes with one arm64 executable slice, the staged
  shader bundle, recursive native-closure checks, and an ad hoc signature.
  There is no valid Developer ID identity on this host, so Developer ID signing,
  notarization, Gatekeeper distribution acceptance, and launch on a clean Apple
  Silicon macOS 26 machine remain external release gates.
- The current M4 Pro host (macOS 26.6, 24 GiB unified memory, 16-core GPU) has
  passed focused Metal/IOSurface tests, the hardware VideoToolbox gate, exact
  arm64 packaging, and a synthetic real-window Metal launch. M1 plus real-host
  1080p/4K, fixed 60 Hz/ProMotion, resize/occlusion, at least 95 percent source
  presentation, zero GPU errors, and zero normal-viewer BGRA materialization
  remain external acceptance gates. The current Apple/container live gate also
  still needs its custom KVM kernel and local QEMU image restored before rerun.

The listener-independent Stage F implementation is locally closed. The current
warnings-as-errors gate passes 356 tests in 69 suites. The current Rocky
yuv420p H.264/H.265 native composition gate is closed; broader codec profiles,
resolutions, and display behavior remain part of the real-host gate. Smartcard
hardware, a redirected USB device, human-audible Playback/device route
switching, physical microphone capture, and migration remain explicit external
gates rather than locally validated claims.

## Source baseline

```text
Package: spice-protocol 0.14.5
URL: https://www.spice-space.org/download/releases/spice-protocol-0.14.5.tar.xz
SHA-256: baf58449f6e89d19f475899ad5fb9196fdc46c03cc53233f4e39cf2978f9cff7
License: BSD-3-Clause
```

QUIC backend:

```text
Package: spice-gtk 0.42 source release (spice-common QUIC implementation)
Linkage: package-provided arm64 static XCFramework
License: LGPL-2.1-or-later
```

## Acceptance commands

The current warnings-as-errors gate passes 356 tests in 69 suites, `swift build`,
the generated-protocol consistency check, and exact-arm64 app packaging with
recursive native-closure verification.

```sh
swift build --disable-sandbox -Xswiftc -warnings-as-errors
swift test --disable-sandbox -Xswiftc -warnings-as-errors
swift package --allow-writing-to-package-directory generate-spice-protocol --check
./Scripts/build-and-run.sh --package
```

The repository-backed Apple/container live gate is:

```sh
Integration/AppleContainer/build-qemu-image.sh
Integration/AppleContainer/build-guest-initramfs.sh
Integration/AppleContainer/run-live-closure.sh

# Rich Agent closure (file transfer, clipboard, and two-head layout)
Integration/AppleContainer/build-agent-initramfs.sh
SWIFTSPICE_GUEST_INITRAMFS="$PWD/Integration/AppleContainer/Artifacts/agent-initramfs.cpio.gz" \
SWIFTSPICE_REQUIRE_AGENT=1 \
SWIFTSPICE_EXERCISE_FILE_TRANSFER=1 \
SWIFTSPICE_EXERCISE_CLIPBOARD=1 \
SWIFTSPICE_EXERCISE_MONITOR_CONFIGURATION=1 \
SWIFTSPICE_GUEST_SETTLE_SECONDS=5 \
Integration/AppleContainer/run-live-closure.sh
```

The live script requires the custom nested-virtualization kernel described in
`Integration/AppleContainer/APPLE_CONTAINER.md`. Its base gate validates ticket
authentication, Display/Cursor/Inputs observations, and guest receipt of the
injected physical A-key scan code. The richer opt-in gate additionally validates
Agent file transfer, bidirectional UTF-8 clipboard, QEMU UI-info monitor
configuration, and the final XRandR layout. It does not install or change macOS
CA trust.

When a server becomes available:

```sh
SPICE_PASSWORD='...' swift run spice-probe HOST PORT
SPICE_PASSWORD='...' swift run spice-probe HOST TLS_PORT --tls
```
