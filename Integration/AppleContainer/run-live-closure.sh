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
readonly REQUIRE_AGENT="${SWIFTSPICE_REQUIRE_AGENT:-0}"
readonly EXERCISE_FILE_TRANSFER="${SWIFTSPICE_EXERCISE_FILE_TRANSFER:-0}"
readonly EXERCISE_CLIPBOARD="${SWIFTSPICE_EXERCISE_CLIPBOARD:-0}"
readonly EXERCISE_MONITOR_CONFIGURATION="${SWIFTSPICE_EXERCISE_MONITOR_CONFIGURATION:-0}"
readonly TRACE_AGENT="${SWIFTSPICE_TRACE_AGENT:-0}"
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

qemu_trace_arguments=()
if [[ "${TRACE_AGENT}" == 1 ]]; then
    qemu_trace_arguments+=(
        -trace enable=spice_vmc_write
        -trace enable=spice_vmc_read
        -trace enable=spice_chr_discard_write
        -trace enable=vdagent_*
        -trace enable=qemu_spice_ui_info
    )
fi

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
        "${qemu_trace_arguments[@]}" \
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
    probe_arguments=(
        127.0.0.1 "${HOST_PORT}"
        --observe-seconds "${OBSERVE_SECONDS}"
        --exercise-input
    )
    if [[ "${REQUIRE_AGENT}" == 1 ]]; then
        probe_arguments+=(--require-agent)
    fi
    if [[ "${EXERCISE_FILE_TRANSFER}" == 1 ]]; then
        probe_arguments+=(--exercise-file-transfer)
    fi
    if [[ "${EXERCISE_CLIPBOARD}" == 1 ]]; then
        probe_arguments+=(--exercise-clipboard)
    fi
    if [[ "${EXERCISE_MONITOR_CONFIGURATION}" == 1 ]]; then
        probe_arguments+=(--exercise-monitor-config)
    fi
    SPICE_PASSWORD="${PASSWORD}" swift run spice-probe "${probe_arguments[@]}"
)

echo "Guest evidence:"
guest_log="$(container logs "${CONTAINER_NAME}")"
printf '%s\n' "${guest_log}" | tail -n 100
if ! printf '%s\n' "${guest_log}" | grep -q '01 00 1e 00 01 00 00 00'; then
    echo "Guest did not record the injected A-key down event (EV_KEY code 30)." >&2
    exit 1
fi
if [[ "${REQUIRE_AGENT}" == 1 ]] \
    && ! printf '%s\n' "${guest_log}" | grep -q 'AGENT_STACK_STARTED'; then
    echo "Guest Agent stack did not reach its started marker." >&2
    exit 1
fi
if [[ "${EXERCISE_FILE_TRANSFER}" == 1 ]] \
    && ! printf '%s\n' "${guest_log}" \
        | grep -q 'FILE_TRANSFER_COMPLETE name=swiftspice-live.txt bytes=30 sha256=4bf33369c4fbbc129f229aad561aaf480cb483e0e3bc419c0e95fa648bc8bc10'; then
    echo "Guest did not persist the expected Agent file-transfer fixture." >&2
    exit 1
fi
if [[ "${EXERCISE_CLIPBOARD}" == 1 ]] \
    && ! printf '%s\n' "${guest_log}" \
        | grep -q 'CLIPBOARD_HOST_TO_GUEST_COMPLETE bytes=26 sha256=24fc28c7400c5b8aa8d2ba4d4223d555f76391235f1d2b4de2c26f904c58b90f'; then
    echo "Guest did not read the expected host clipboard fixture." >&2
    exit 1
fi
if [[ "${EXERCISE_MONITOR_CONFIGURATION}" == 1 ]] \
    && ! printf '%s\n' "${guest_log}" | grep -q 'XRANDR_DUAL_MONITOR_COMPLETE'; then
    echo "Guest XRandR did not enable both requested monitors." >&2
    exit 1
fi
if [[ "${EXERCISE_CLIPBOARD}" == 1 ]] \
    && ! printf '%s\n' "${guest_log}" | grep -q 'CLIPBOARD_GUEST_TO_HOST_OFFERED'; then
    echo "Guest did not offer its clipboard fixture to the host." >&2
    exit 1
fi
