# Apple/container live closure harness

This harness runs a nested arm64 QEMU/SPICE guest inside Apple/container and
then exercises it with the repository's `spice-probe`. It closes behavior that
unit tests cannot prove: live Display frames, Cursor state, Inputs
acknowledgements, and delivery of a physical PC scan-code transition to the
booted guest.

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

Then run the live gate:

```sh
Integration/AppleContainer/run-live-closure.sh
```

The script publishes only `127.0.0.1:15930`, waits for the listener, runs
`spice-probe --exercise-input`, requires the guest log to contain the injected
A-key down transition (`EV_KEY`, code 30), prints guest evidence, and removes
its named container on success, failure, or interruption. Environment overrides include
`SWIFTSPICE_HOST_PORT`, `SWIFTSPICE_PASSWORD`, `SWIFTSPICE_OBSERVE_SECONDS`,
`SWIFTSPICE_GUEST_SETTLE_SECONDS`, and `SWIFTSPICE_QEMU_IMAGE`.

This minimal guest does not contain a desktop, `spice-vdagent`, or an audio
stack. Consequently clipboard, file transfer, multi-monitor Agent negotiation,
Playback, and Record remain separate external gates.
