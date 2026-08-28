# Rocky x86_64 SPICE performance fixture

This fixture runs a disposable Alpine guest under rootless Podman and KVM on a
configured Rocky SSH host. It is isolated from the Apple/container closure and
uses the unique container name `swiftspice-perf-ab-qemu`. Set the alias once in
the invoking shell; `rocky9` is the current fixture host:

```sh
export SWIFTSPICE_ROCKY_SSH_HOST=rocky9
```

The endpoint is deliberately bound only to remote loopback:

- SPICE: `127.0.0.1:5935`
- guest load control: `127.0.0.1:5936`
- fixed guest display: `1280x720`

Connect one client at a time through an SSH tunnel:

```sh
ssh -N -L 15935:127.0.0.1:5935 "${SWIFTSPICE_ROCKY_SSH_HOST}"
```

Read the per-run ticket only when configuring the client:

```sh
ssh "${SWIFTSPICE_ROCKY_SSH_HOST}" \
  '$HOME/swiftspice-remote-closure/perf-ab/remote/ticket.sh'
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
desktop. `remote/stop.sh` stops QEMU. Start/reset always begins the same
30-frame-per-second animation at frame zero. A successful start requires both
the SPICE and guest-control loopback listeners. Startup failure removes the
container, log follower, temporary ticket, and active-run state while retaining
the run directory for diagnosis. Start and stop hold one cross-process lifecycle
lock, so concurrent starts serialize and a failed start finishes its cleanup
before another start can publish an endpoint. Run-directory names include an
atomic random suffix, so two attempts in the same second cannot collide. Guest
builds use temporary rootfs and artifact directories, validate the manifest and
hashes, and only then acquire the same lifecycle lock and replace the prior
build. The build holds that lock through backup cleanup, while start holds it
through artifact verification, evidence capture, and QEMU detach. Before
launch, the kernel and initramfs SHA-256 values must match
`artifacts/build-manifest.env`.

Archive a server-log slice around each client capture:

```sh
~/swiftspice-remote-closure/perf-ab/remote/round.sh begin swiftspice
~/swiftspice-remote-closure/perf-ab/remote/round.sh end
```

Each run and round records QEMU, spice-server, Podman and guest versions plus
the exact SPICE codec/compression configuration under `perf-ab/logs/`.
