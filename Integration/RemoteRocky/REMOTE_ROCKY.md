# Rocky x86_64 SPICE performance fixture

This fixture runs a disposable Alpine guest under rootless Podman and KVM on
the SSH host `rocky8`. It is isolated from the Apple/container closure and uses
the unique container name `swiftspice-perf-ab-qemu`.

The endpoint is deliberately bound only to remote loopback:

- SPICE: `127.0.0.1:5935`
- guest load control: `127.0.0.1:5936`
- fixed guest display: `1280x720`

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

`control.sh stop` stops only the animated workload and returns to the static
desktop. `remote/stop.sh` stops QEMU. Start creates the deterministic xterm;
reset signals its existing generator to return to frame zero, avoiding X-client
churn while preserving the same 30-frame-per-second starting phase.

After changing the guest image or reset path, exercise at least ten alternating
five-second pairs and require every client sample to pass the activity-span,
time-bucket, and last-frame-age gates before starting a formal 10x30-second
comparison. The 2026-08-02 signal-reset image produced 20/20 valid 720p stress
samples and 19/20 at 4K, so 4K remains below this prerequisite. See
[`Benchmarks/RESULTS_ROCKY8_2026-08-02.md`](../../Benchmarks/RESULTS_ROCKY8_2026-08-02.md)
for the evidence and exact rerun boundary.

Archive a server-log slice around each client capture:

```sh
~/swiftspice-remote-closure/perf-ab/remote/round.sh begin swiftspice
~/swiftspice-remote-closure/perf-ab/remote/round.sh end
```

Each run and round records QEMU, spice-server, Podman and guest versions plus
the exact SPICE codec/compression configuration under `perf-ab/logs/`.
