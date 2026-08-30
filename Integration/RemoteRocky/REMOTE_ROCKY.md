# Rocky x86_64 SPICE performance fixture

This fixture runs a disposable Alpine guest under rootless Podman and KVM on a
configured Rocky SSH host. It is isolated from the Apple/container closure.
The default lifecycle remains compatible with the existing
`swiftspice-perf-ab-qemu` container. A separate experiment must set its own
base, container, image, and ports in every lifecycle shell; values are strictly
validated before Podman or state paths are touched. Set the alias once in the
invoking shell; `rocky9` is the current fixture host:

```sh
export SWIFTSPICE_ROCKY_SSH_HOST=rocky9
```

The endpoint is deliberately bound only to remote loopback:

- SPICE: `127.0.0.1:5935`
- guest load control: `127.0.0.1:5936`
- fixed guest display: `1280x720`

For the AIP-00b live gate, use an independently built/deployed fixture rather
than reusing or stopping the default endpoint:

```sh
export SWIFTSPICE_PERF_BASE="$HOME/swiftspice-aip00b/perf-ab"
export SWIFTSPICE_PERF_CONTAINER=swiftspice-aip00b-qemu
export SWIFTSPICE_PERF_IMAGE=localhost/swiftspice-qemu-x86:local
export SWIFTSPICE_PERF_SPICE_PORT=5945
export SWIFTSPICE_PERF_CONTROL_PORT=5946
```

Container names accept only lowercase letters, digits, dot, underscore, and
dash, beginning with a letter or digit. Image references accept lowercase
repository path components and an optional OCI-style tag. The selected
container and image are copied into each run's `configuration.txt`; start,
stop, status, control, ticket, and round scripts all inherit the same isolated
base and container values. The five override variables above are an all-or-none
identity: a partial environment, including a later shell that retains the base
or ports but loses the container or image, exits with status 2 before creating
state or invoking Podman. The base must use one canonical absolute spelling;
trailing slashes, repeated slashes, and dot segments are rejected rather than
normalized to a potentially different lifecycle identity. With all five unset,
the historical default lifecycle remains unchanged.

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

Build the Alpine guest with its dedicated builder image from the repository
root. The QEMU runtime image intentionally contains neither a C compiler nor
the guest build toolchain:

```sh
podman build \
  --file Integration/RemoteRocky/GuestBuilder.Containerfile \
  --tag localhost/swiftspice-guest-builder:alpine-3.22 \
  Integration/RemoteRocky
podman run --rm \
  --volume "$PWD/Integration/RemoteRocky:/work:Z" \
  localhost/swiftspice-guest-builder:alpine-3.22 \
  /work/build-guest.sh
```

The builder is based on Alpine 3.22 and pins `build-base`, `libxi-dev`,
`fortify-headers`, and the util-linux `flock` subpackage. The build script
requires Alpine's `cc`, produces the marker clock helper as a static musl
binary, and builds the native XI2 event monitor against libXi/libX11. The guest
runtime pins those two libraries but contains no compiler or headers. An
incomplete builder is rejected before any staged rootfs or artifacts are
created. Do not add `--userns=keep-id`: `apk --root` must run as root inside
the container to create and populate the guest chroot. Podman itself remains a
rootless process owned by the invoking Rocky user; container root is mapped
through the rootless user namespace and does not grant host root privileges.
It publishes verified output under `Integration/RemoteRocky/rootfs` and
`Integration/RemoteRocky/artifacts`, serialized with the same lifecycle lock
used by start and stop.

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
The static and animated fullscreen xterms use the same marker renderer as
their terminal entry point. Rows 1-4 are reserved for the marker while both
workloads render from row 6 onward. For the animated workload, marker output
briefly stops the generator; an xterm terminal-status response confirms the
ROI write was consumed before the renderer acknowledges the marker and resumes
animation. The terminal-response barrier has one aggregate half-second bound;
its byte-state parser ignores unrelated input, including printable `n`, and
accepts only exact `ESC [ 0 n` before one absolute monotonic deadline. EOF,
malformed-only input, or timeout produces no acknowledgement. Thus a
fullscreen workload cannot stack above or repaint the ROI after the
acknowledgement. A DSR timeout taints the persistent renderer. Before any later
marker draw, it sends the distinct cursor-position query `ESC [ 6 n` and waits
for an exact `ESC [ <row> ; <column> R` response. A late `ESC [ 0 n` from the
old DSR is consumed but cannot satisfy this pre-draw resynchronization fence;
only a successful cursor report permits the new draw and its own DSR. A failed
fence leaves the renderer tainted and produces neither a draw nor an ACK. The
guest agent waits at most two seconds for this renderer
acknowledgement and drains any nonmatching stale revision within that same
overall bound; a late revision may enter the FIFO, but it cannot satisfy or
poison the current event. A monotonic nanosecond deadline is recorded before request
publication. The agent opens the request FIFO read/write, publishes one small
fixed record, and closes it immediately. The renderer keeps its request FIFO
read/write descriptor open for its entire main loop, including marker
processing, so a second request cannot lose its reader between publication and
the next read. With no renderer, the agent's open cannot block and closing its
final endpoint discards the unconsumed record rather than delivering it to a
future workload. A missing acknowledgement or unexpected
marker revision fails the event without emitting `marker_drawn`, releases the marker
state lock, and lets the supervised input monitor restart instead of hanging.
The XI2 monitor consumes only RawKeyPress, RawButtonPress, and RawMotion; it
ignores each delivered counterpart so one physical input cannot consume a
second arm. It dispatches through a serialized worker so the XI2 reader keeps
draining during marker processing. Key and click events stay FIFO; an atomic
motion ownership token coalesces every later RawMotion delivered while one
motion epoch is open. The native source owns one X connection, selects only
RawKeyPress, RawButtonPress, and RawMotion on the root window, completes an
`XSync` round trip, and only then atomically publishes its private ready file.
Before the next arm, the invocation sync rotates that XI2 source: it terminates
the old helper, drains all stdout already published through EOF, and closes the
old X connection so unread upstream events cannot cross generations. The
monitor observes the new helper's application-level ready publication before
placing the checkpoint behind the old epoch's agent work. Only after that
worker checkpoint clears motion ownership does it
permit the sync echo. This is an explicit XI2-source/FIFO/worker epoch boundary,
not a sleep-based burst heuristic. The checkpoint's single bounded wait budget
covers monitor/source startup and the subsequent worker acknowledgement. Guest
timestamps come from a statically linked
`clock_gettime(CLOCK_MONOTONIC)` helper rather than `/proc/uptime`'s coarse
text representation. Startup requires the manifest capability
`guest_marker_clock=clock_gettime-monotonic-v1`, and a missing or malformed
clock sample fails the event explicitly. Startup also requires
`guest_xi2_monitor=native-xi2-select-sync-v1` plus the pinned libXi/libX11
runtime versions and `guest_marker_roi=binary-grid-v1`; `xinput` remains
installed only for input diagnostics. The binary marker contains magic
`0xA5C3`, the 16-lowercase-hex token, the guest UInt64 marker revision, and the
8-lowercase-hex checksum in an 88-by-2 bit grid of 4-by-4 BGRA cells. The guest
draw helper targets the active xterm's `WINDOWID`, aligns the ROI in the
bounded top-left search region, and completes `XSync` before the existing DSR
visibility barrier may acknowledge it. Its encode-only build mode emits the
same tightly packed 352-by-8 BGRA layout without requiring X11, so host tests
and the guest renderer do not maintain separate encoders.
Each host `arm` invocation is serialized and first sends a random 128-bit
control barrier. The guest strictly accepts 32 lowercase hexadecimal digits
and echoes `PERF_CONTROL_SYNC invocation=<id>` to the serial log. The host waits
for that exact barrier, then records a fresh byte boundary before sending the
real arm; delayed responses from an earlier invocation therefore cannot satisfy
a retry. A missing barrier fails with a bounded, structured sync error and no
arm is sent. Neither the barrier nor its log record contains the SPICE ticket.
The guest image pins `xf86-input-libinput`; without that Xorg input driver,
SPICE input can reach the guest device while producing no XI2 event for the
marker monitor. The build manifest records the exact driver package version,
and startup rejects an older artifact that omits it.

For a live harness that must not poll `server.log`, use the streaming form on
the same isolated endpoint:

```sh
~/swiftspice-aip00b/perf-ab/remote/control.sh trace click 0123456789abcdef
```

`trace` owns the same arm lock and unique sync boundary as `arm`. It first
prints the exact `PERF_ARMED` line; the local harness sends its real input only
after reading that line. Sync, arm acceptance, and the matching
`guest_received` followed by `marker_drawn` share one bounded
`PERF_CONTROL_WAIT_ATTEMPTS` retry budget. The two evidence lines are printed
only when action, token, and marker revision agree. A duplicate, malformed,
reversed, mismatched, or timed out sequence exits nonzero with
`PERF_TRACE_ERROR`. Unrelated log traffic is ignored, and neither output path
reads or prints the SPICE ticket.

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
normalized per-event records using schema version 2. A record includes host
input and send timing, optional motion ACK, guest marker timing, display
receive, Surface ready, selected-revision ready, selection, Metal commit,
presented time, marker checksum, desktop generation, display channel ID,
surface ID, and the Surface lifecycle/frame revision/delivery identity.
Missing or ambiguous evidence is recorded as invalid rather than paired with a
nearby frame.

The package-only `SpiceInteractionTraceCapture` attaches exactly one assembler
to a session's presentation diagnostics, caches one finished record, and uses
`SpiceInteractionTraceJSONLWriter` for bounded mode-0600 publication. Writer
publication is serialized by a sidecar lock, validates every existing schema-2
line, writes a same-directory temporary inode, fsyncs it, replaces the output,
and fsyncs the directory. An exact existing line makes a retry idempotent. The
remote normalizer applies the same derived-validity rules and never reads the
ticket. Stream one macOS-produced record to an independently selected run:

```sh
cat input-event.json | ssh "${SWIFTSPICE_ROCKY_SSH_HOST}" \
  '$HOME/swiftspice-aip00b/perf-ab/remote/collect-input-events.sh "$HOME/swiftspice-aip00b/perf-ab/logs/RUN_ID"'
```

Malformed JSON or a record without a stable pair/version/run/order/action/token
attribution is rejected without writing. Attributable but incomplete evidence
is atomically retained with `valid=false` and a deterministic reason. The
record and whole file are capped at 64 KiB and 16 MiB respectively.

A harness may await
`SpiceInteractionTraceCapture.waitForExactPresentation(waiterRegistered:)`
without polling. The one-shot wait returns the exact frame identity only after
that capture selected and committed it and the real AppKit presented callback
accepted the same delivery. An earlier accepted presentation is cached;
unrelated in-flight deliveries do not wake it, task cancellation removes the
waiter, and finishing the capture terminates an outstanding wait without
finishing or appending on the wait path itself.

Run the exact-presentation gate as its own foreground AppKit process, not from
the Swift Testing host:

```sh
ssh -N -L 15945:127.0.0.1:5945 rocky9
```

In a second terminal:

```sh
SWIFTSPICE_LIVE_INTERACTION=1 \
SWIFTSPICE_ROCKY_SSH_HOST=rocky9 \
SWIFTSPICE_PERF_BASE=/home/USER/swiftspice-aip00b/perf-ab \
SWIFTSPICE_PERF_CONTAINER=swiftspice-aip00b-qemu \
SWIFTSPICE_PERF_IMAGE=localhost/swiftspice-qemu-x86:local \
SWIFTSPICE_PERF_SPICE_PORT=5945 \
SWIFTSPICE_PERF_CONTROL_PORT=5946 \
SWIFTSPICE_LIVE_ENDPOINT_HOST=127.0.0.1 \
SWIFTSPICE_LIVE_ENDPOINT_PORT=15945 \
SWIFTSPICE_LIVE_VERSION=v0.3.3 \
swift run -c release spice-live-interaction
```

`spice-live-interaction` is a regular foreground `NSApplication` with a real
visible `NSWindow` and `SpiceDesktopView`. It waits for one visible desktop
subscription and a Metal commit plus actual presented callback before arming.
It then streams the isolated `control.sh trace` transaction, records host input
before sending a direct session click, waits for the matching guest pair and
the exact presented delivery, and sends the resulting schema-2 line to the
isolated run collector. The five `SWIFTSPICE_PERF_*` identity values, both live
endpoint values, and a canonical
`SWIFTSPICE_LIVE_VERSION=vMAJOR.MINOR.PATCH` are mandatory; the historical
default container, base, and `5935`/`5936` endpoint (including its prior
`15935` local forward) are rejected. SSH stdout and stderr stay separate,
and the ticket is used only as in-process credentials and is never printed.

On failure, the harness finishes the capture without substituting a coarse
harness reason, preserving such derived reasons as `missing_display_receive`,
`missing_selection`, `missing_metal_commit`, or `missing_presented`; it then
best-effort appends that invalid record and exits nonzero. Only a safe stage,
non-secret framebuffer-readiness counters, and local record path are reported.
The direct session click intentionally bypasses the AppKit input queue, so a
successful run closes marker-to-exact-presented correlation but does not
measure input-event queue latency.

The drawable callback treats `CAMetalDrawable.presentedTime == 0` as dropped,
not as a host timestamp. When the dropped identity is still the latest selected
revision and visible demand remains, the desktop may request one authoritative
latest-only redraw for that revision. A second consecutive drop for the same
revision does not retry again; success or a newer revision resets the budget.
The recovery never fabricates presentation evidence, commits without an update,
or relaxes the two-command GPU in-flight limit. A run that cannot obtain an
initial actual-presented callback still fails before arm.

The guest marker is assembled completely in client memory as a native-depth
`XImage`, then published to the selected topmost viewable descendant with one
standalone `XPutImage` followed by `XSync`. Do not branch on the `XPutImage`
return value: Xlib does not define it as the request's success result, and
protocol errors are dispatched by the synchronization round trip. This keeps
the binary-grid layout and terminal barrier/ACK ordering while preventing the
old per-cell `XSetForeground`/`XFillRectangle` requests from creating visible
intermediate marker frames that perturb latency measurement.

The host records `scheduledNs`, `hostInputNs`, and `sendStartedNs` before the
wire send, then records `sendCompletedNs` after its continuation resumes. This
lets a causally eligible Display frame arriving during the send continuation be
retained instead of being dropped for lack of host evidence. A motion ACK may
be buffered before send completion; the completion stage may confirm that same
timestamp, while a different or duplicate completion fails closed.

The state machine can be exercised without X using the same validation and
renderer call point:

```sh
printf '%s\n' \
  'arm action_class=click token=0123456789abcdef' \
  'input action_class=click guest_ns=100' |
  /usr/local/bin/input-marker-agent.sh --self-test-jsonl
```

This local slice makes the shared pixel protocol, exact host correlation, and
normalized JSONL schema deterministically testable. It does not by itself
prove a live Rocky marker was included in a particular AppKit `presented`
callback. The host detector synchronously samples only the bounded top-left
marker ROI at aligned origins 8 through 32 from an immutable publication; an
IOSurface read is closure-scoped
and does not populate the full-frame CPU materialization cache. A new
independent Rocky run must bind the unique marker evidence to
the exact presented revision before the event is valid for
click/key/motion-to-visible acceptance.

The Rocky run at
`/home/beribeli/swiftspice-remote-closure/perf-ab/logs/20260828T170315Z.cfDtZd`
confirmed the current client-to-guest subpath after adding eudev discovery:
Xorg/libinput registered the Virtio keyboard and mouse plus the hotplug SPICE
tablet. The Release mode-aware probe produced `guest_received` and
`marker_drawn` for key token `4444`, motion token `5555`, and click token
`6666`; the motion run observed two SPICE ACKs. This does not associate marker
pixels with an exact SwiftSpice frame revision or AppKit presented callback.
That association belongs in `input-events.jsonl` and remains required evidence.

The independently named `5945`/`5946` fixture run at
`/home/beribeli/swiftspice-aip00b/perf-ab/logs/20260829T061937Z.9FuYes`
also captured the arm-to-guest marker smoke sequence. It is guest-causal
evidence only. The run did not use the package wait to bind marker pixels to an
exact SwiftSpice frame and AppKit presented callback, so it is not a completed
input-to-visible trace or a latency result.

Archive a server-log slice around each client capture:

```sh
~/swiftspice-remote-closure/perf-ab/remote/round.sh begin swiftspice
~/swiftspice-remote-closure/perf-ab/remote/round.sh end
```

Each run and round records QEMU, spice-server, Podman and guest versions plus
the exact SPICE codec/compression configuration under `perf-ab/logs/`.
