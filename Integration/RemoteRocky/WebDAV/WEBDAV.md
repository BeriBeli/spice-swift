# Rocky WebDAV live gate

This independent fixture uses `swiftspice-webdav-live-qemu` and remote port
`127.0.0.1:5945`; it does not restart or modify the performance A/B endpoint.

The macOS client connects through:

```sh
ssh -N -L 15945:127.0.0.1:5945 rocky8
```

The live gate attaches a read-only `SpiceWebDAVServer`, sends a real guest
request through `org.spice-space.webdav.0`, mounts the endpoint with davfs2,
and verifies `swiftspice-webdav-live.txt` inside the guest. Tickets are stored
mode 0600 and read via `remote/ticket.sh`; start output never prints them.

Deploy and build the disposable guest without deleting prior run evidence:

```sh
rsync -a Integration/RemoteRocky/WebDAV/ \
  rocky8:~/swiftspice-remote-closure/webdav-live/
ssh rocky8 'podman run --rm \
  --volume ~/swiftspice-remote-closure/webdav-live:/work:Z \
  docker.io/library/alpine:3.22 /bin/sh /work/build-guest.sh'
ssh rocky8 ~/swiftspice-remote-closure/webdav-live/remote/start.sh
```

With the tunnel active, read the temporary ticket into the process environment
without printing it:

```sh
SPICE_PASSWORD="$(ssh rocky8 \
  ~/swiftspice-remote-closure/webdav-live/remote/ticket.sh 2>/dev/null)" \
  swift run spice-probe 127.0.0.1 15945 --exercise-webdav
ssh rocky8 ~/swiftspice-remote-closure/webdav-live/remote/status.sh
```

A successful guest serial log contains both markers:

```text
WEBDAV_GET_COMPLETE name=swiftspice-webdav-live.txt
WEBDAV_MOUNT_COMPLETE name=swiftspice-webdav-live.txt bytes=31 sha256=492d1e4f0bc7e1ce3ae8d06e597d4197dbe5029ff75956f720938f940499b297
```

Stop the endpoint after capture; this also removes its temporary ticket:

```sh
ssh rocky8 ~/swiftspice-remote-closure/webdav-live/remote/stop.sh
```

The 2026-08-01 closure used QEMU 8.2.2, spice-server 0.15.1, Alpine
linux-virt 6.12.98, spice-webdavd 3.0-r4, and davfs2 1.6.1-r2. SPICE used
`image-compression=auto_glz` and `streaming-video=off`.
