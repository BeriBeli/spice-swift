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
~/swiftspice-remote-closure/perf-ab/remote/control.sh diagnose-input
~/swiftspice-remote-closure/perf-ab/remote/status.sh
~/swiftspice-remote-closure/perf-ab/remote/stop.sh
```

`control.sh stop` stops only the animated workload and returns to the static
desktop. `remote/stop.sh` stops QEMU. Start/reset always begins the same
30-frame-per-second animation at frame zero. A successful start requires both
the SPICE and guest-control loopback listeners. Startup failure removes the
container, log follower, temporary ticket, and active-run state only after
Podman confirms that the fixed container no longer exists. If teardown cannot
be confirmed, the command fails and preserves the ticket, follower PID, and run
evidence for audit. Start and stop hold one cross-process lifecycle lock, so
concurrent starts serialize and a failed start finishes its cleanup before
another start can publish an endpoint. The lifecycle shell itself owns
the lock; QEMU detach and the persistent log follower explicitly close the lock
descriptor before launch. If no fixed container is running, start and stop
discard inactive state without signalling a persisted follower PID; start does
so before it arms the new run's failure cleanup. Stop defers an observed
termination signal until its container and active-state cleanup completes. Run
directory names include an atomic random suffix, so two attempts in the same
second cannot collide. Lifecycle cleanup never signals the recorded follower
PID: removing the container lets `podman logs --follow` exit naturally, and its
PID record is discarded only after Podman confirms the container is absent.
Guest builds use temporary rootfs and artifact directories, validate the
manifest and
hashes, and only then acquire the same lifecycle lock and replace the prior
build. The build holds that lock through backup cleanup, while start holds it
through artifact verification, evidence capture, and QEMU detach. Before
launch, the kernel and initramfs SHA-256 values must match
`artifacts/build-manifest.env`.

## Causal input marker seam

Arm exactly one guest marker before sending the corresponding real input:

```sh
~/swiftspice-remote-closure/perf-ab/remote/control.sh \
  arm click 0123456789abcdef
```

The action class is `click`, `key`, or `motion`; the token is exactly 16
lowercase hexadecimal characters. A second arm is rejected while one is
outstanding, and a token cannot be reused during the guest boot. Inputs of a
different class do not consume the arm. The first matching X input emits
`guest_received`, renders a fixed black-on-white marker ROI containing the
token, monotonically increasing guest marker revision, and the first eight
hexadecimal digits of `SHA-256(token)`, then emits `marker_drawn`. Autonomous
animation never consumes an arm and is not a causal interaction endpoint.
The guest image pins `xf86-input-libinput`; without that Xorg input driver,
SPICE input can reach the guest device while producing no XI2 event for the
marker monitor. The build manifest records the exact driver package version,
and startup rejects an older artifact that omits it.

When live input does not reach the marker, capture the guest discovery state:

```sh
~/swiftspice-remote-closure/perf-ab/remote/control.sh diagnose-input
```

The diagnostic prints the X input hierarchy, relevant Xorg
input/libinput/keyboard/mouse/tablet log lines, and kernel input Name/Handlers
records between stable begin/end markers. It contains no SPICE ticket.

The Release probe chooses its pointer messages only after receiving the first
desktop snapshot and its pointer mode:

```sh
.build/release/spice-probe HOST PORT \
  --observe-seconds 30 --exercise-input
```

Supply `SPICE_PASSWORD` through the invoking environment as for other probe
runs; do not place the live ticket in the command.

The probe always sends a key down/up pair first and a left press/release last.
In absolute mode it sends only changing `mousePosition` coordinates on display
zero; in relative mode it sends only `mouseMotion`. Both pointer sequences keep
the SPICE motion/position flow-control ACK gate.

The guest's raw `PERF_TRACE` records remain in `server.log`.
`PERF_MARKER_RENDER` is emitted by the deterministic self-test at the same
renderer call point; production presents the corresponding ROI in X. Each new
run also creates a mode-0600 `input-events.jsonl`; the host collector appends
normalized per-event records using schema version 1. A record includes host
input and send timing, optional motion ACK, guest marker timing, display
receive, Surface ready, selected-revision ready, selection, Metal commit,
presented time, and the Surface generation/frame revision/delivery identity.
Missing or ambiguous evidence is recorded as invalid rather than paired with a
nearby frame.

The state machine can be exercised without X using the same validation and
renderer call point:

```sh
printf '%s\n' \
  'arm action_class=click token=0123456789abcdef' \
  'input action_class=click guest_ns=100' |
  /usr/local/bin/input-marker-agent.sh --self-test-jsonl
```

This slice makes guest causality and the normalized JSONL schema
deterministically testable. It does not yet prove that the marker's pixels were
included in a particular AppKit `presented` callback. A live Rocky run must
bind the unique marker evidence to the exact presented revision before the
event is valid for click/key/motion-to-visible acceptance.

The Rocky run at
`/home/beribeli/swiftspice-remote-closure/perf-ab/logs/20260828T170315Z.cfDtZd`
confirmed the current client-to-guest subpath after adding eudev discovery:
Xorg/libinput registered the Virtio keyboard and mouse plus the hotplug SPICE
tablet. The Release mode-aware probe produced `guest_received` and
`marker_drawn` for key token `4444`, motion token `5555`, and click token
`6666`; the motion run observed two SPICE ACKs. This does not associate marker
pixels with an exact SwiftSpice frame revision or AppKit presented callback.
That association belongs in `input-events.jsonl` and remains required evidence.

Archive a server-log slice around each client capture:

```sh
~/swiftspice-remote-closure/perf-ab/remote/round.sh begin swiftspice
~/swiftspice-remote-closure/perf-ab/remote/round.sh end
```

Each run and round records QEMU, spice-server, Podman and guest versions plus
the exact SPICE codec/compression configuration under `perf-ab/logs/`.
