#!/bin/sh

set -eu

readonly input=/input
readonly work=/work
readonly rootfs="${work}/rootfs"
readonly artifacts="${work}/artifacts"

rm -rf "${rootfs}" "${artifacts}"
mkdir -p "${rootfs}" "${artifacts}"
gzip -dc "${input}/perf-initramfs.cpio.gz" | (
    cd "${rootfs}"
    cpio -id 2>/dev/null
)
install -m 0755 "${work}/guest/animation-load.sh" \
    "${rootfs}/usr/local/bin/animation-load.sh"
install -m 0755 /usr/local/libexec/swiftspice-x11-animation \
    "${rootfs}/usr/local/bin/swiftspice-x11-animation"
install -m 0755 /usr/local/libexec/swiftspice-stream-device-agent \
    "${rootfs}/usr/local/bin/swiftspice-stream-device-agent"
install -d -m 0755 "${rootfs}/usr/local/share/swiftspice"
install -m 0644 /usr/local/share/swiftspice/stream.h264 \
    "${rootfs}/usr/local/share/swiftspice/stream.h264"
install -m 0644 /usr/local/share/swiftspice/stream-h264-metadata.txt \
    "${rootfs}/usr/local/share/swiftspice/stream-h264-metadata.txt"
install -m 0644 /usr/local/share/swiftspice/stream.h265 \
    "${rootfs}/usr/local/share/swiftspice/stream.h265"
install -m 0644 /usr/local/share/swiftspice/stream-h265-metadata.txt \
    "${rootfs}/usr/local/share/swiftspice/stream-h265-metadata.txt"
install -m 0755 "${work}/guest/init" "${rootfs}/init"
cp "${input}/vmlinuz-virt" "${artifacts}/vmlinuz-virt"
(
    cd "${rootfs}"
    find . -print | cpio -o -H newc 2>/dev/null | gzip -9 \
        > "${artifacts}/perf-initramfs.cpio.gz"
)
du -h "${artifacts}/vmlinuz-virt" "${artifacts}/perf-initramfs.cpio.gz"
