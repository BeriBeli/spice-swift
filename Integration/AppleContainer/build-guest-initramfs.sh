#!/bin/bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ALPINE_VERSION="3.22.5"
readonly ALPINE_ARCHIVE="alpine-minirootfs-${ALPINE_VERSION}-aarch64.tar.gz"
readonly ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/aarch64/${ALPINE_ARCHIVE}"
readonly ALPINE_SHA256="3fbc6285032ed46821b511292633d7b2a6306a2e254f590e92bdafff56cf2f70"
readonly OUTPUT="${1:-${SCRIPT_DIR}/Artifacts/initramfs.cpio.gz}"
readonly DOWNLOAD_CACHE="${SCRIPT_DIR}/Artifacts/${ALPINE_ARCHIVE}"
readonly WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/swiftspice-initramfs.XXXXXX")"

cleanup() {
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

mkdir -p "$(dirname "${OUTPUT}")" "${WORK_DIR}/rootfs"
if [[ ! -f "${DOWNLOAD_CACHE}" ]]; then
    curl -fsSL "${ALPINE_URL}" -o "${DOWNLOAD_CACHE}"
fi

actual_sha256="$(shasum -a 256 "${DOWNLOAD_CACHE}" | awk '{print $1}')"
if [[ "${actual_sha256}" != "${ALPINE_SHA256}" ]]; then
    echo "Alpine checksum mismatch: expected ${ALPINE_SHA256}, got ${actual_sha256}" >&2
    exit 1
fi

tar -xzf "${DOWNLOAD_CACHE}" -C "${WORK_DIR}/rootfs"
install -m 0755 "${SCRIPT_DIR}/guest/init" "${WORK_DIR}/rootfs/init"

(
    cd "${WORK_DIR}/rootfs"
    find . -print | LC_ALL=C sort | cpio -o -H newc 2>/dev/null | gzip -9 > "${OUTPUT}"
)

echo "Built ${OUTPUT}"
