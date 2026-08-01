#!/bin/sh

set -eu

readonly rootfs=/work/rootfs
readonly artifacts=/work/artifacts
readonly source=/work/guest

rm -rf "${rootfs}" "${artifacts}"
mkdir -p "${rootfs}" "${artifacts}"

apk \
    --root "${rootfs}" \
    --keys-dir /etc/apk/keys \
    --initdb \
    --no-cache \
    --repository https://dl-cdn.alpinelinux.org/alpine/v3.22/main \
    --repository https://dl-cdn.alpinelinux.org/alpine/v3.22/community \
    add \
        alpine-base=3.22.5-r0 \
        dbus=1.16.2-r1 \
        font-dejavu=2.37-r6 \
        linux-virt=6.12.98-r0 \
        openbox=3.6.1-r8 \
        spice-vdagent=0.22.1-r2 \
        spice-webdavd=3.0-r4 \
        xclip=0.13-r3 \
        xorg-server=21.1.19-r0 \
        xrandr=1.5.2-r0 \
        xsetroot=1.1.3-r1 \
        xterm=399-r0

install -m 0755 "${source}/init" "${rootfs}/init"
install -d -m 0755 "${rootfs}/etc/X11" "${rootfs}/usr/local/bin"
install -m 0644 "${source}/xorg.conf" "${rootfs}/etc/X11/xorg.conf"
install -m 0755 "${source}/static-desktop.sh" "${rootfs}/usr/local/bin/static-desktop.sh"
install -m 0755 "${source}/animation-load.sh" "${rootfs}/usr/local/bin/animation-load.sh"
install -m 0755 "${source}/animation-generator.sh" "${rootfs}/usr/local/bin/animation-generator.sh"

cp "${rootfs}/boot/vmlinuz-virt" "${artifacts}/vmlinuz-virt"
(
    cd "${rootfs}"
    find . -print | cpio -o -H newc 2>/dev/null | gzip -9 > "${artifacts}/perf-initramfs.cpio.gz"
)

printf 'guest kernel: '
basename "$(readlink -f "${rootfs}/boot/vmlinuz-virt")"
du -h "${artifacts}/vmlinuz-virt" "${artifacts}/perf-initramfs.cpio.gz"
