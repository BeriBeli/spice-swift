#!/bin/bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly OUTPUT="${SCRIPT_DIR}/Artifacts/agent-initramfs.cpio.gz"
readonly ROOTFS_ARCHIVE="${SCRIPT_DIR}/Artifacts/agent-rootfs-3.22-v3.tar.gz"
readonly WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/swiftspice-agent-initramfs.XXXXXX")"
readonly ALPINE_MIRROR="${SWIFTSPICE_ALPINE_MIRROR:-https://mirror.freedif.org/alpine}"

cleanup() {
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

mkdir -p "${SCRIPT_DIR}/Artifacts" "${WORK_DIR}/rootfs"

if [[ ! -f "${ROOTFS_ARCHIVE}" ]]; then
    container run \
        --rm \
        --memory 2g \
        --env "SWIFTSPICE_ALPINE_MIRROR=${ALPINE_MIRROR}" \
        --volume "${WORK_DIR}:/work" \
        --volume "${SCRIPT_DIR}/guest:/swiftspice-guest:ro" \
        alpine:3.22 \
        sh /swiftspice-guest/build-agent-rootfs.sh
    mv "${WORK_DIR}/agent-rootfs.tar.gz" "${ROOTFS_ARCHIVE}"
fi

container run \
    --rm \
    --memory 2g \
    --volume "${SCRIPT_DIR}/Artifacts:/work" \
    --volume "${SCRIPT_DIR}/guest:/swiftspice-guest:ro" \
    alpine:3.22 \
    sh -c '
        mkdir /rootfs
        tar -xzf /work/agent-rootfs-3.22-v3.tar.gz -C /rootfs
        cp /swiftspice-guest/agent-init /rootfs/init
        mkdir -p /rootfs/etc/X11
        cp /swiftspice-guest/xorg.conf /rootfs/etc/X11/xorg.conf
        chmod 0755 /rootfs/init
        cd /rootfs
        find . -print | LC_ALL=C sort | cpio -o -H newc 2>/dev/null \
            | gzip -1 > /work/agent-initramfs.cpio.gz.tmp
        mv /work/agent-initramfs.cpio.gz.tmp /work/agent-initramfs.cpio.gz
    '

echo "Built ${OUTPUT}"
