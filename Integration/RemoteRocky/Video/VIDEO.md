# Rocky advanced-video live gate

This fixture is isolated from the performance and WebDAV endpoints. It uses
`swiftspice-video-live-qemu`, remote loopback ports `5955`/`5956`, and an
independent mode-0600 temporary ticket. A minimal guest stream-device agent
sends deterministic 1280x720, 30 fps, yuv420p H.264 Constrained Baseline and
H.265 Main Annex-B sequences through `org.spice-space.stream.0`. Each access
unit is framed with the official stream-device protocol and is sent only when
the connected client advertises that codec and the workload has been started.

The prior host-encoding probe remains useful evidence: Ubuntu's SPICE 0.15.1
pipeline negotiates Y444 and produces H.264 High 4:4:4, which VideoToolbox
rejects. This revision bypasses that host encoder without patching
`libspice-server1`; `streaming-video=off` ensures the H.264 stream originates
only from the guest stream-device fixture.

The macOS client connects through:

```sh
ssh -N -L 15955:127.0.0.1:5955 rocky8
```

Run the opt-in client gate with:

```sh
SPICE_PASSWORD="$(ssh rocky8 \
  ~/swiftspice-remote-closure/video-live/remote/ticket.sh)" \
swift run spice-probe 127.0.0.1 15955 \
  --observe-seconds 8 --benchmark-json --enable-h264 --require-native-video
```

Substitute `--enable-h265` for the HEVC Main gate. The two opt-ins are mutually
exclusive so each run proves one codec selection.

The live gate requires `STREAM_AGENT ... selected=h264|h265 streaming=1`,
`STREAM_AGENT reset_frame=0`, at least two published frames, at least one
VideoToolbox decode and native Metal composition, and zero VT/general BGRA
materialization, advanced/native fallback, GPU error, or stream-generation
disable. `--require-native-video` enforces those client-side conditions. A
default-policy negative run must report `selected=none streaming=0`. Start
output never prints the ticket; read it only into the client process environment
with `remote/ticket.sh`.
