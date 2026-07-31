#!/bin/sh

set -eu

readonly alpine_mirror="${SWIFTSPICE_ALPINE_MIRROR:-https://mirror.freedif.org/alpine}"

mkdir /rootfs
apk \
    --root /rootfs \
    --keys-dir /etc/apk/keys \
    --initdb \
    --no-cache \
    --repository "${alpine_mirror}/v3.22/main" \
    --repository "${alpine_mirror}/v3.22/community" \
    add \
        alpine-base=3.22.5-r0 \
        dbus=1.16.2-r1 \
        spice-vdagent=0.22.1-r2 \
        xclip=0.13-r3 \
        xorg-server=21.1.19-r0 \
        xrandr=1.5.2-r0 \
        xvfb-run=1.20.10.3-r2

# devtmpfs supplies device nodes when the nested guest boots. Excluding the
# package-created nodes also makes the archive extractable by an unprivileged
# macOS user.
tar --exclude='./dev/*' -C /rootfs -czf /work/agent-rootfs.tar.gz .
