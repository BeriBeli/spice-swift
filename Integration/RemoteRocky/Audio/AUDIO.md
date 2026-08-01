# Rocky audio live gate

This fixture boots an isolated Alpine x86_64 guest with QEMU's SPICE audio
backend and an ICH9 HDA duplex codec. The SPICE and control sockets listen only
on the Rocky host loopback. The temporary ticket is never printed by start or
status commands.

The default ports and names are independent from the performance and video
fixtures:

- SPICE: remote `127.0.0.1:5965`, tunnel locally to `127.0.0.1:15965`
- control: remote `127.0.0.1:5966`
- container: `swiftspice-audio-live-qemu`
- state and logs: `~/swiftspice-remote-closure/audio-live`

`remote/control.sh` accepts `playback-start`, `record-start`, `reset`, `stop`,
and `status`. Run only one client and one workload at a time. Read the ticket
only into `SPICE_PASSWORD`, for example:

```sh
ssh -N -L 15965:127.0.0.1:5965 rocky8
SPICE_PASSWORD="$(ssh rocky8 '~/swiftspice-remote-closure/audio-live/remote/ticket.sh')" \
  swift run --disable-sandbox spice-probe 127.0.0.1 15965 --exercise-playback
```

For the synthetic Record transport gate, reset the guest, run
`remote/control.sh record-start`, and invoke the probe with
`--exercise-record-synthetic`. The guest writes a 15-second raw S16LE capture
and records its byte count and SHA-256 in the per-run server log.

`build-guest.sh` creates the pinned Alpine 3.22 guest. `repack-guest.sh` is the
fast path after changing only `guest/init`; mount the matching 6.12.98 perf
rootfs at `/kernel-root` and its artifacts at `/kernel-artifacts`.

The Playback gate proves that RAW PCM reaches and starts the macOS
`AVAudioEngine` sink and reports scheduled packet/frame counts; human-audible
output and route switching still require an operator. The synthetic Record gate
proves client-to-guest PCM transport and a
guest `arecord` artifact, but does not claim microphone permission or physical
input-device coverage.
