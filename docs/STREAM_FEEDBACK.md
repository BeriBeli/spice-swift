# Video stream feedback

## Why feedback matters

The comparison uses the official [spice-gtk 0.43 source archive](https://www.spice-space.org/download/gtk/spice-gtk-0.43.tar.xz)
and [spice-server 0.15.2 source archive](https://www.spice-space.org/download/releases/spice-0.15.2.tar.bz2).

- spice-gtk enables adaptive streaming by default unless
  `SPICE_DISABLE_ADAPTIVE_STREAMING` is set. It advertises
  `SPICE_DISPLAY_CAP_STREAM_REPORT` in `src/channel-display.c`.
- The server's `server/video-stream.cpp:video_stream_agent_create` creates the
  MJPEG encoder with an initial bandwidth estimate regardless of this capability.
  It sends `STREAM_ACTIVATE_REPORT` only when the client advertises feedback.
- In `server/mjpeg-encoder.c`, server-side frame drops can call
  `mjpeg_encoder_decrease_bit_rate` without any client report. The sole caller
  of `mjpeg_encoder_increase_bit_rate` is the positive-client-report handler.
  Thus absence of reports removes that recovery path; it does not disable
  server-side rate control or guarantee high JPEG quality.
- Reports can also cause downshifts when arrival margins indicate congestion.
  Enabling reports restores a control loop, not a request for lossless text.

The observed remote session delivered 1920 × 1015, 4:2:0 JPEG frames whose
quantizer signatures changed from quality 50 to 40 on 2026-10-30. Earlier
samples matched quality 80 and 20. These are quantizer-based inferences, not
an explicit JPEG quality field. They establish compression loss before local
rendering, but do not identify the remote server version or the cause of its
initial downshift. The source comparison supports missing recovery feedback as
a concrete defect; real-server testing and user-session quality recovery are
separate validation claims.

## Implementation contract

- Generate Display server message 319 and client message 102 from the protocol
  schema. Report bodies contain eight 32-bit little-endian fields; the video
  delay field is signed. Decode activation bodies with exact length checks.
- Keep each server activation's unique ID and window inside its stream lifetime.
  Reactivation replaces accumulated state. Stream/surface destruction and reset
  discard it. Connection replacement clears it until the target activates a
  new window, even when surfaces and decoders survive migration.
- Match spice-gtk's **arrival** statistics: count regular and sized stream
  messages; count negative wrapping multimedia-time margins as late arrivals.
  Decode completion, queue coalescing and host presentation are different
  measurements. Do not describe report frame counts as displayed FPS.
- Send a report at the server's frame-count threshold, monotonic timeout checked
  on a subsequent arrival, or three consecutive negative margins. Reset the
  window after emitting. Zero thresholds report on each arrival, as upstream
  does; idle periods never synthesize empty reports.
- Preserve `UInt32` multimedia timestamps and signed wrapping differences.
  Timeout accounting uses a local `ContinuousClock`, independent of multimedia
  clock resets. Report the actual last host-sink audio delay when known;
  otherwise use `UInt32.max`. Clear measured audio delay on Playback STOP/close.
- Sample before decoding, then send after MJPEG admission so the current frame
  can decode while the report is written. Use the originating connection for
  writes, propagate send errors, and reject stale state after clock awaits.
- Keep existing MJPEG coalescing, pre-decode late drops, admitted-late-frame
  publication, stream order, generation checks and Surface mutation barriers.

## Validation

Deterministic tests cover byte layout and malformed activation messages,
capability advertisement, window size/timeout/consecutive-drop behavior,
timestamp wraparound, no-audio/measured-audio behavior, ordinary and sized
frames, reactivation, stream-ID reuse, migration, and feedback while decoding
is blocked and intermediate frames are coalesced. Existing frame-order and
mutation-barrier regressions remain part of the Display suite.

Use the repository's serial full-suite command (also used by CI/release):

```sh
swift test --disable-sandbox --no-parallel -Xswiftc -warnings-as-errors
swift build --disable-sandbox -Xswiftc -warnings-as-errors
swift package --allow-writing-to-package-directory generate-spice-protocol --check
```

Live peer validation passed against spice-server 0.15.2: in a low-initial-rate,
extended streaming fixture, 54 accepted reports triggered 12 bitrate increases
and JPEG quality ultimately recovered from 20 to 80. The server also sent sized
frames. Details and the still-pending remote-session visual check are recorded
in [STATUS.md](STATUS.md). No installed application update is part of this change.
