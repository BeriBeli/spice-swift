# Rocky x86_64 SPICE performance fixture

This fixture runs a disposable Alpine guest under rootless Podman and KVM on
the SSH host `rocky8`. It is isolated from the Apple/container closure and uses
the unique container name `swiftspice-perf-ab-qemu`.

The endpoint is deliberately bound only to remote loopback:

- SPICE: `127.0.0.1:5935`
- guest load control: `127.0.0.1:5936`
- default guest display: `1280x720`; isolated fixtures may carry a separately
  built `3840x2160` guest/QEMU configuration

Connect one client at a time through an SSH tunnel:

```sh
ssh -N -L 15935:127.0.0.1:5935 rocky8
```

Read the per-run ticket only when configuring the client:

```sh
ssh rocky8 ~/swiftspice-remote-closure/perf-ab/remote/ticket.sh
```

Do not put the ticket on a shared command line or in committed configuration.
Stopping the endpoint deletes it. The QEMU command receives only the path to a
mode-0600 secret file.

Remote lifecycle commands:

```sh
~/swiftspice-remote-closure/perf-ab/remote/start.sh
~/swiftspice-remote-closure/perf-ab/remote/control.sh start
~/swiftspice-remote-closure/perf-ab/remote/control.sh reset
~/swiftspice-remote-closure/perf-ab/remote/control.sh stop
~/swiftspice-remote-closure/perf-ab/remote/status.sh
~/swiftspice-remote-closure/perf-ab/remote/stop.sh
```

The host wrappers can target an isolated fixture without changing the default
deployment. The path must be absolute and end in `/remote`; the optional round
evidence directory receives the exact completed round's server log, generator
telemetry, configuration, and version files:

```sh
SWIFTSPICE_BENCH_REMOTE_ROCKY_DIRECTORY=/home/beribeli/swiftspice-remote-closure/direct-bb3b176-20260803-v1-4k/remote \
SWIFTSPICE_BENCH_ROUND_EVIDENCE_DIRECTORY=/private/tmp/swiftspice-renderer-pairs-4k/remote-rounds \
SWIFTSPICE_BENCH_HOOK_SCRIPT=Benchmarks/remote_rocky_hook.sh \
SWIFTSPICE_BENCH_BOOT_EPOCH_SCRIPT=Benchmarks/remote_rocky_boot_epoch.sh \
SWIFTSPICE_BENCH_RESOLUTION=3840x2160 \
Benchmarks/run_renderer_pairs.sh 127.0.0.1 15935 10 30 \
  /private/tmp/swiftspice-renderer-pairs-4k
```

`SWIFTSPICE_BENCH_RESOLUTION` only declares and validates the expected
frame-byte footprint. It does not resize Xorg or QEMU, so a real 4K run must
use a fixture already built and verified at 3840x2160.

`control.sh stop` stops only the animated workload and returns to the static
desktop. `remote/stop.sh` stops QEMU. Start creates the deterministic xterm;
reset signals its existing generator to return to frame zero, avoiding X-client
churn while preserving the same 30-frame-per-second starting phase. Every start
or reset advances a guest-side generation. The generator emits a serial-console
record after its first completed frame and then after every 30 completed frames:

```text
PERF_GENERATOR event=heartbeat generation=7 frame_id=120 monotonic_uptime_seconds=842.31 pid=417 boot_epoch=8b3c8d9e-...
```

This is intentionally about one write per second rather than one write per
frame. `frame_id` advances only after the shell has finished writing a complete
terminal frame. `monotonic_uptime_seconds` comes from `/proc/uptime`, and the
PID remains stable for signal-based resets while `generation` changes. A
stalled generator therefore stops producing records; if these records continue
while the client frame counter stops, the stall is downstream of the generator.
The record does not count X11 Present or Damage events, so by itself it cannot
separate xterm/Xorg, spice-server, transport, and client stalls.

`remote/boot-epoch.sh` asks the running guest for its Linux boot ID and prints
exactly that one value. The benchmark wrappers can use it to reject a QEMU
restart during a batch; the `boot_epoch` on every generator record supplies an
independent log cross-check.

After changing the guest image or reset path, exercise at least ten alternating
five-second pairs and require every client sample to pass the activity-span,
time-bucket, and last-frame-age gates before starting a formal 10x30-second
comparison. Also run a full-duration preflight. At `bb3b176`, both direct
`cpu-iosurface`/`metal` batches collected all 20 samples, but the 720p batch had
nine incomplete-activity samples and the 4K batch had eight. Guest generator
heartbeats continued through every failed client sample, so the failure is
downstream of the generator; the retained records cannot yet distinguish
xterm, Xorg, spice-server, transport, and client paths. Replace or repair that
path and add X11 Present/Damage evidence before a formal verdict. See the
[direct report](../../Benchmarks/RESULTS_DIRECT_ROCKY8_2026-08-03.md) for this
follow-up. The earlier
[selected-Swift-versus-GLib report](../../Benchmarks/RESULTS_ROCKY8_2026-08-03.md)
and the 2026-08-02 report remain historical evidence.

Archive a server-log slice around each client capture:

```sh
~/swiftspice-remote-closure/perf-ab/remote/round.sh begin swiftspice
~/swiftspice-remote-closure/perf-ab/remote/round.sh end
```

Each run and round records QEMU, spice-server, Podman and guest versions plus
the exact SPICE codec/compression configuration under `perf-ab/logs/`. In
addition to the raw `*-server.log`, `round.sh end` extracts every
`PERF_GENERATOR` record into `*-guest-telemetry.log`. A healthy 30-second
capture should contain a reset/start record followed by steadily increasing
heartbeats for its generation and PID. Because a round begins immediately
before reset, its log may have one leading heartbeat from the previous
generation; evaluate continuity from the newest reset/start record. Missing
records, a frame counter that stops advancing, or an unexpected generation/PID
transition after that boundary invalidate the fixture evidence and should be
compared with the client's published-frame activity before assigning the stall
to the guest or client pipeline.

Validate the copied generator evidence separately from the renderer analyzer:

```sh
uv run Benchmarks/analyze_guest_telemetry.py \
  /private/tmp/swiftspice-renderer-pairs-4k \
  /private/tmp/swiftspice-renderer-pairs-4k/remote-rounds \
  --expected-pairs 10 --observe-seconds 30
```

Both analyzers are required: client activity can fail while the generator
telemetry remains healthy, which is exactly what the `bb3b176` direct run
observed.
