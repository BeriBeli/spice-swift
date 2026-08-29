#!/bin/bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

acquire_lifecycle_lock

if [[ "$(podman inspect --format '{{.State.Running}}' "${PERF_CONTAINER}" 2>/dev/null || true)" == true ]]; then
    echo "Performance endpoint is already running."
    exec "$(dirname "${BASH_SOURCE[0]}")/status.sh"
fi

remove_inactive_endpoint_locked

startup_complete=false
cleanup_failed_start() {
    result=$?
    trap - EXIT HUP INT TERM
    if [[ "${startup_complete}" != true ]]; then
        if stop_endpoint_locked; then
            echo "Performance endpoint startup failed; active state was removed." >&2
        else
            exit 1
        fi
    fi
    exit "${result}"
}
trap cleanup_failed_start EXIT
trap 'exit 1' HUP INT TERM

manifest="${PERF_ARTIFACTS}/build-manifest.env"
if [[ ! -r "${PERF_ARTIFACTS}/vmlinuz-virt" \
    || ! -r "${PERF_ARTIFACTS}/perf-initramfs.cpio.gz" \
    || ! -r "${manifest}" ]]; then
    echo "Guest artifacts are missing; run the guest build first." >&2
    exit 1
fi
if grep -Evq '^[a-z0-9_]+=[A-Za-z0-9._:+-]+$' "${manifest}"; then
    echo "Guest build manifest is malformed." >&2
    exit 1
fi
required_manifest_keys=(
    manifest_version
    guest_marker_clock
    guest_marker_roi
    guest_xi2_monitor
    guest_kernel
    guest_alpine_base
    guest_coreutils
    guest_dbus
    guest_eudev
    guest_font_dejavu
    guest_libx11
    guest_libxi
    guest_linux_virt
    guest_openbox
    guest_spice_vdagent
    guest_spice_webdavd
    guest_xclip
    guest_xf86_input_libinput
    guest_xinput
    guest_xorg_server
    guest_xrandr
    guest_xsetroot
    guest_xterm
    guest_kernel_sha256
    guest_initramfs_sha256
)
for key in "${required_manifest_keys[@]}"; do
    if [[ "$(grep -c "^${key}=" "${manifest}")" != 1 ]]; then
        echo "Guest build manifest must contain ${key} exactly once." >&2
        exit 1
    fi
done
if [[ "$(grep -c '^manifest_version=1$' "${manifest}")" != 1 \
    || "$(grep -c '^guest_marker_clock=clock_gettime-monotonic-v1$' "${manifest}")" != 1 \
    || "$(grep -c '^guest_marker_roi=binary-grid-v1$' "${manifest}")" != 1 \
    || "$(grep -c '^guest_xi2_monitor=native-xi2-select-sync-v1$' "${manifest}")" != 1 \
    || "$(grep -c '^guest_kernel=linux-virt-[0-9][A-Za-z0-9._+-]*$' "${manifest}")" != 1 \
    || "$(grep -c '^guest_kernel_sha256=[0-9a-f]\{64\}$' "${manifest}")" != 1 \
    || "$(grep -c '^guest_initramfs_sha256=[0-9a-f]\{64\}$' "${manifest}")" != 1 ]]; then
    echo "Guest build manifest is incomplete." >&2
    exit 1
fi
expected_kernel_sha256="$(sed -n 's/^guest_kernel_sha256=//p' "${manifest}")"
expected_initramfs_sha256="$(sed -n 's/^guest_initramfs_sha256=//p' "${manifest}")"
actual_kernel_sha256="$(sha256sum "${PERF_ARTIFACTS}/vmlinuz-virt" | awk '{print $1}')"
actual_initramfs_sha256="$(sha256sum "${PERF_ARTIFACTS}/perf-initramfs.cpio.gz" | awk '{print $1}')"
if [[ "${actual_kernel_sha256}" != "${expected_kernel_sha256}" \
    || "${actual_initramfs_sha256}" != "${expected_initramfs_sha256}" ]]; then
    echo "Guest artifacts do not match the build manifest." >&2
    exit 1
fi

run_prefix="$(date -u +%Y%m%dT%H%M%SZ)"
run_dir="$(mktemp -d "${PERF_LOGS}/${run_prefix}.XXXXXX")"
run_id="${run_dir##*/}"
mkdir -p "${run_dir}/rounds"
chmod 0700 "${run_dir}" "${run_dir}/rounds"
: > "${run_dir}/input-events.jsonl"
chmod 0600 "${run_dir}/input-events.jsonl"

ticket="$(openssl rand -hex 24)"
umask 077
printf '%s' "${ticket}" > "${PERF_STATE}/ticket"
printf '%s\n' "${run_id}" > "${PERF_STATE}/current-run"

cat > "${run_dir}/configuration.txt" <<EOF
run_id=${run_id}
resolution=1280x720
spice_listen=127.0.0.1:${PERF_SPICE_PORT}
control_listen=127.0.0.1:${PERF_CONTROL_PORT}
image_compression=auto_glz
jpeg_wan_compression=auto
zlib_glz_wan_compression=auto
streaming_video=filter
playback_compression=on
interaction_trace_schema=2
interaction_trace_path=${run_dir}/input-events.jsonl
container=${PERF_CONTAINER}
image=${PERF_IMAGE}
EOF
cat "${manifest}" >> "${run_dir}/configuration.txt"
cp "${manifest}" "${run_dir}/guest-build-manifest.env"

podman run --rm "${PERF_IMAGE}" qemu-system-x86_64 --version > "${run_dir}/versions.txt"
podman run --rm "${PERF_IMAGE}" dpkg-query -W libspice-server1 qemu-system-x86 qemu-system-modules-spice \
    >> "${run_dir}/versions.txt"
podman version >> "${run_dir}/versions.txt"

container_id="$(podman run --detach \
    --name "${PERF_CONTAINER}" \
    --device /dev/kvm \
    --network host \
    --volume "${PERF_ARTIFACTS}:/guest:ro,Z" \
    --volume "${PERF_STATE}:/state:ro,Z" \
    "${PERF_IMAGE}" \
    qemu-system-x86_64 \
        -nodefaults \
        -no-user-config \
        -machine q35,accel=kvm \
        -cpu host \
        -smp 4 \
        -m 2048 \
        -kernel /guest/vmlinuz-virt \
        -initrd /guest/perf-initramfs.cpio.gz \
        -append 'console=ttyS0 panic=-1' \
        -device virtio-vga,max_outputs=1,xres=1280,yres=720 \
        -device virtio-keyboard-pci \
        -device virtio-mouse-pci \
        -device virtio-serial-pci \
        -chardev spicevmc,id=vdagent,name=vdagent \
        -device virtserialport,chardev=vdagent,name=com.redhat.spice.0 \
        -chardev "socket,id=perf-control,host=127.0.0.1,port=${PERF_CONTROL_PORT},server=on,wait=off" \
        -device virtserialport,chardev=perf-control,name=org.swiftspice.perf.control \
        -object secret,id=spice-password,file=/state/ticket \
        -spice "port=${PERF_SPICE_PORT},addr=127.0.0.1,password-secret=spice-password,image-compression=auto_glz,jpeg-wan-compression=auto,zlib-glz-wan-compression=auto,streaming-video=filter,playback-compression=on" \
        -display none \
        -serial stdio \
        -monitor none \
        -no-reboot \
        9>&-)"
printf '%s\n' "${container_id}" > "${run_dir}/container-id.txt"

nohup podman logs --follow "${PERF_CONTAINER}" 9>&- > "${run_dir}/server.log" 2>&1 &
printf '%s\n' "$!" > "${PERF_STATE}/log-follower.pid"

ready=false
for _ in $(seq 1 60); do
    if loopback_port_is_listening "${PERF_SPICE_PORT}" \
        && loopback_port_is_listening "${PERF_CONTROL_PORT}" \
        && grep -q 'PERF_READY resolution=1280x720' "${run_dir}/server.log" 2>/dev/null; then
        ready=true
        break
    fi
    sleep 1
done

if [[ "${ready}" != true ]]; then
    echo "Endpoint did not become ready; inspect ${run_dir}/server.log" >&2
    podman logs "${PERF_CONTAINER}" >> "${run_dir}/server.log" 2>&1 || true
    exit 1
fi

startup_complete=true
trap - EXIT HUP INT TERM
echo "Performance endpoint ready."
echo "SPICE: 127.0.0.1:${PERF_SPICE_PORT} on $(hostname)"
echo "Read the temporary ticket with remote/ticket.sh and keep it out of logs."
echo "Run evidence: ${run_dir}"
