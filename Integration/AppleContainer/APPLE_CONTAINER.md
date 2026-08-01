# Apple/container live closure harness

This harness runs a nested arm64 QEMU/SPICE guest inside Apple/container and
then exercises it with the repository's `spice-probe`. The base guest closes
live Display frames, Cursor state, Inputs acknowledgements, and physical PC
scan-code delivery. An optional Xorg/spice-vdagent guest also closes bounded
file transfer, bidirectional UTF-8 clipboard, and two-head monitor layout.

## Requirements

- Apple silicon with nested virtualization support (M3 or newer).
- Apple/container 1.2.0.
- A container kernel with KVM plus `CONFIG_DRM_VIRTIO_GPU=y`,
  `CONFIG_VIRTIO_INPUT=y`, and `CONFIG_VIRTIO_CONSOLE=y`. The currently
  validated baseline is Apple containerization 0.40.1 / Linux 6.18.5.
- `curl`, `cpio`, `gzip`, and the Swift 6 toolchain on the host.

The large kernel and initramfs artifacts are deliberately excluded from Git.
The scripts default to the retained kernel used by the milestone and the
repository-local generated initramfs:

```text
/private/tmp/apple-containerization-0.40.1/bin/vmlinux-arm64
Integration/AppleContainer/Artifacts/initramfs.cpio.gz
```

Override them with `SWIFTSPICE_OUTER_KERNEL` and
`SWIFTSPICE_GUEST_INITRAMFS`. The outer container kernel and nested guest kernel
may be the same file.

## Run

Build the QEMU image once:

```sh
Integration/AppleContainer/build-qemu-image.sh
```

Optionally reproduce the pinned Alpine 3.22.5 initramfs:

```sh
Integration/AppleContainer/build-guest-initramfs.sh
```

Build the richer Agent/Xorg initramfs when exercising Agent integration:

```sh
Integration/AppleContainer/build-agent-initramfs.sh
```

Then run the live gate:

```sh
Integration/AppleContainer/run-live-closure.sh
```

The script publishes only `127.0.0.1:15930`, waits for the listener, runs
`spice-probe --exercise-input`, requires the guest log to contain the injected
A-key down transition (`EV_KEY`, code 30), prints guest evidence, and removes
its named container on success, failure, or interruption. Environment overrides
include `SWIFTSPICE_HOST_PORT`, `SWIFTSPICE_PASSWORD`,
`SWIFTSPICE_OBSERVE_SECONDS`, `SWIFTSPICE_GUEST_SETTLE_SECONDS`, and
`SWIFTSPICE_QEMU_IMAGE`.

Run the complete Agent closure with:

```sh
SWIFTSPICE_GUEST_INITRAMFS="$PWD/Integration/AppleContainer/Artifacts/agent-initramfs.cpio.gz" \
SWIFTSPICE_REQUIRE_AGENT=1 \
SWIFTSPICE_EXERCISE_FILE_TRANSFER=1 \
SWIFTSPICE_EXERCISE_CLIPBOARD=1 \
SWIFTSPICE_EXERCISE_MONITOR_CONFIGURATION=1 \
SWIFTSPICE_GUEST_SETTLE_SECONDS=5 \
Integration/AppleContainer/run-live-closure.sh
```

The Agent guest uses exact Alpine 3.22 package revisions and an ignored cached
rootfs archive. It checks the transferred file's byte count and SHA-256, exact
clipboard fixtures in both directions, and a final XRandR layout with
Virtual-1 at 800x600+0+0 and Virtual-2 at 640x480+800+0.

With virtio-gpu, spice-server consumes `VD_AGENT_MONITORS_CONFIG` in QEMU's
`client_monitors_config` callback; it is not forwarded over the vdagent virtio
port and therefore has no `VD_AGENT_REPLY`. Set `SWIFTSPICE_TRACE_AGENT=1` to
record the corresponding `qemu_spice_ui_info` evidence. The bare Xorg image has
no desktop settings daemon, so its init applies the connector hotplug using an
explicit xrandr auto-layout policy.

The minimal guest still has no Agent or audio stack. Playback and Record remain
separate QEMU/hardware gates; the richer guest does not claim audible output or
microphone capture.
