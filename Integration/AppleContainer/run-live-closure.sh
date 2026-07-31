#!/bin/bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly CONTAINER_NAME="${SWIFTSPICE_CONTAINER_NAME:-swiftspice-live-closure}"
readonly IMAGE_NAME="${SWIFTSPICE_QEMU_IMAGE:-swiftspice-qemu:local}"
readonly OUTER_KERNEL="${SWIFTSPICE_OUTER_KERNEL:-/private/tmp/apple-containerization-0.40.1/bin/vmlinux-arm64}"
readonly GUEST_INITRAMFS="${SWIFTSPICE_GUEST_INITRAMFS:-${SCRIPT_DIR}/Artifacts/initramfs.cpio.gz}"
readonly HOST_PORT="${SWIFTSPICE_HOST_PORT:-15930}"
readonly GUEST_PORT="${SWIFTSPICE_GUEST_PORT:-5930}"
readonly PASSWORD="${SWIFTSPICE_PASSWORD:-swiftspice-local}"
readonly OBSERVE_SECONDS="${SWIFTSPICE_OBSERVE_SECONDS:-8}"
readonly GUEST_SETTLE_SECONDS="${SWIFTSPICE_GUEST_SETTLE_SECONDS:-2}"
readonly KERNEL_DIR="$(cd "$(dirname "${OUTER_KERNEL}")" && pwd)"
readonly INITRAMFS_DIR="$(cd "$(dirname "${GUEST_INITRAMFS}")" && pwd)"
readonly KERNEL_NAME="$(basename "${OUTER_KERNEL}")"
readonly INITRAMFS_NAME="$(basename "${GUEST_INITRAMFS}")"

if [[ ! -f "${OUTER_KERNEL}" ]]; then
    echo "Missing nested-virtualization kernel: ${OUTER_KERNEL}" >&2
    exit 1
fi
if [[ ! -f "${GUEST_INITRAMFS}" ]]; then
    echo "Missing guest initramfs: ${GUEST_INITRAMFS}" >&2
    echo "Run Integration/AppleContainer/build-guest-initramfs.sh or set SWIFTSPICE_GUEST_INITRAMFS." >&2
    exit 1
fi

remove_container() {
    container stop "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    container delete --force "${CONTAINER_NAME}" >/dev/null 2>&1 || true
}

finish() {
    status=$?
    trap - EXIT INT TERM
    if [[ "${status}" -ne 0 ]]; then
        echo "QEMU/container evidence after failure:" >&2
        container logs "${CONTAINER_NAME}" >&2 || true
    fi
    remove_container
    exit "${status}"
}
trap finish EXIT INT TERM

remove_container

container run \
    --detach \
    --name "${CONTAINER_NAME}" \
    --cpus 4 \
    --memory 4g \
    --virtualization \
    --kernel "${OUTER_KERNEL}" \
    --publish "127.0.0.1:${HOST_PORT}:${GUEST_PORT}" \
    --volume "${KERNEL_DIR}:/swiftspice/kernel:ro" \
    --volume "${INITRAMFS_DIR}:/swiftspice/guest:ro" \
    "${IMAGE_NAME}" \
    qemu-system-aarch64 \
        -nodefaults \
        -no-user-config \
        -machine virt,gic-version=3,accel=kvm \
        -cpu host \
        -smp 2 \
        -m 1024 \
        -kernel "/swiftspice/kernel/${KERNEL_NAME}" \
        -initrd "/swiftspice/guest/${INITRAMFS_NAME}" \
        -append "console=ttyAMA0 panic=-1" \
        -device virtio-gpu-pci,romfile=,max_outputs=2 \
        -device virtio-keyboard-pci,romfile= \
        -device virtio-mouse-pci,romfile= \
        -device virtio-serial-pci,romfile= \
        -chardev spicevmc,id=vdagent,name=vdagent \
        -device virtserialport,chardev=vdagent,name=com.redhat.spice.0 \
        -object "secret,id=spice-password,data=${PASSWORD}" \
        -spice "port=${GUEST_PORT},addr=0.0.0.0,password-secret=spice-password" \
        -display none \
        -serial stdio \
        -monitor none \
        -no-reboot

ready=false
for _ in $(seq 1 60); do
    if nc -z 127.0.0.1 "${HOST_PORT}" >/dev/null 2>&1; then
        ready=true
        break
    fi
    sleep 1
done

if [[ "${ready}" != true ]]; then
    echo "SPICE listener did not become ready on 127.0.0.1:${HOST_PORT}" >&2
    container logs "${CONTAINER_NAME}" >&2 || true
    exit 1
fi

sleep "${GUEST_SETTLE_SECONDS}"

(
    cd "${REPO_ROOT}"
    SPICE_PASSWORD="${PASSWORD}" swift run spice-probe \
        127.0.0.1 "${HOST_PORT}" \
        --observe-seconds "${OBSERVE_SECONDS}" \
        --exercise-input
)

echo "Guest evidence:"
guest_log="$(container logs "${CONTAINER_NAME}")"
printf '%s\n' "${guest_log}" | tail -n 100
if ! printf '%s\n' "${guest_log}" | grep -q '01 00 1e 00 01 00 00 00'; then
    echo "Guest did not record the injected A-key down event (EV_KEY code 30)." >&2
    exit 1
fi
