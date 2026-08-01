#!/bin/sh

set -eu

readonly rootfs=/work/rootfs
readonly artifacts=/work/artifacts

readonly kernel_version=6.12.98-0-virt
readonly kernel_modules="/kernel-root/lib/modules/${kernel_version}"

if ! test -x "${rootfs}/usr/bin/aplay" || ! test -d "${kernel_modules}"; then
    echo "Expanded audio rootfs is incomplete; run build-guest.sh first." >&2
    exit 1
fi

kernel=/kernel-artifacts/vmlinuz-virt
if ! test -r "${kernel}"; then
    echo "Matching 6.12.98 vmlinuz is unavailable." >&2
    exit 1
fi

mkdir -p "${artifacts}"
rm -rf "${rootfs}/lib/modules/${kernel_version}"
cp -a "${kernel_modules}" "${rootfs}/lib/modules/${kernel_version}"
find "${rootfs}/boot" -name '.apk.*' -delete
install -m 0755 /work/guest/init "${rootfs}/init"
cp "${kernel}" "${artifacts}/vmlinuz-virt"
(
    cd "${rootfs}"
    find . -print | cpio -o -H newc 2>/dev/null | gzip -6 > "${artifacts}/audio-initramfs.cpio.gz"
)

du -h "${artifacts}/vmlinuz-virt" "${artifacts}/audio-initramfs.cpio.gz"
