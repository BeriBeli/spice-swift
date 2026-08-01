#!/bin/bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

if [[ "$(podman inspect --format '{{.State.Running}}' "${PERF_CONTAINER}" 2>/dev/null || true)" == true ]]; then
    echo "Performance endpoint is already running."
    exec "$(dirname "${BASH_SOURCE[0]}")/status.sh"
fi

podman rm --force "${PERF_CONTAINER}" >/dev/null 2>&1 || true

if [[ ! -r "${PERF_ARTIFACTS}/vmlinuz-virt" \
    || ! -r "${PERF_ARTIFACTS}/perf-initramfs.cpio.gz" ]]; then
    echo "Guest artifacts are missing; run the guest build first." >&2
    exit 1
fi

run_id="$(date -u +%Y%m%dT%H%M%SZ)"
run_dir="${PERF_LOGS}/${run_id}"
mkdir -p "${run_dir}/rounds"
chmod 0700 "${run_dir}" "${run_dir}/rounds"

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
guest_kernel=linux-virt-6.12.98-r0
guest_spice_vdagent=0.22.1-r2
guest_spice_webdavd=3.0-r4
EOF

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
        -no-reboot)"
printf '%s\n' "${container_id}" > "${run_dir}/container-id.txt"

nohup podman logs --follow "${PERF_CONTAINER}" > "${run_dir}/server.log" 2>&1 &
printf '%s\n' "$!" > "${PERF_STATE}/log-follower.pid"

ready=false
for _ in $(seq 1 60); do
    if ss -ltn | grep -q "127.0.0.1:${PERF_SPICE_PORT}" \
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

echo "Performance endpoint ready."
echo "SPICE: 127.0.0.1:${PERF_SPICE_PORT} on rocky8"
echo "Read the temporary ticket with remote/ticket.sh and keep it out of logs."
echo "Run evidence: ${run_dir}"
