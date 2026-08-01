#!/bin/sh

set -eu

readonly rootfs=/work/rootfs
readonly artifacts=/work/artifacts

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
        davfs2=1.6.1-r2 \
        linux-virt=6.12.98-r0 \
        spice-webdavd=3.0-r4

install -m 0755 /work/guest/init "${rootfs}/init"
cp "${rootfs}/boot/vmlinuz-virt" "${artifacts}/vmlinuz-virt"
(
    cd "${rootfs}"
    find . -print | cpio -o -H newc 2>/dev/null | gzip -9 > "${artifacts}/webdav-initramfs.cpio.gz"
)

du -h "${artifacts}/vmlinuz-virt" "${artifacts}/webdav-initramfs.cpio.gz"
