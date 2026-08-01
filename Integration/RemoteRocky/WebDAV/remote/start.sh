#!/bin/bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

podman rm --force "${WEBDAV_CONTAINER}" >/dev/null 2>&1 || true
run_id="$(date -u +%Y%m%dT%H%M%SZ)"
run_dir="${WEBDAV_LOGS}/${run_id}"
mkdir -p "${run_dir}"
chmod 0700 "${run_dir}"

ticket="$(openssl rand -hex 24)"
umask 077
printf '%s' "${ticket}" > "${WEBDAV_STATE}/ticket"
printf '%s\n' "${run_id}" > "${WEBDAV_STATE}/current-run"

cat > "${run_dir}/configuration.txt" <<EOF
run_id=${run_id}
spice_listen=127.0.0.1:${WEBDAV_SPICE_PORT}
webdav_channel=org.spice-space.webdav.0
guest_webdav_port=9843
guest_mount=davfs2-read-only
image_compression=auto_glz
streaming_video=off
EOF
podman run --rm "${WEBDAV_IMAGE}" qemu-system-x86_64 --version > "${run_dir}/versions.txt"
podman run --rm "${WEBDAV_IMAGE}" dpkg-query -W libspice-server1 qemu-system-x86 qemu-system-modules-spice \
    >> "${run_dir}/versions.txt"

podman run --detach \
    --name "${WEBDAV_CONTAINER}" \
    --device /dev/kvm \
    --network host \
    --volume "${WEBDAV_ARTIFACTS}:/guest:ro,Z" \
    --volume "${WEBDAV_STATE}:/state:ro,Z" \
    "${WEBDAV_IMAGE}" \
    qemu-system-x86_64 \
        -nodefaults \
        -no-user-config \
        -machine q35,accel=kvm \
        -cpu host \
        -smp 2 \
        -m 1024 \
        -kernel /guest/vmlinuz-virt \
        -initrd /guest/webdav-initramfs.cpio.gz \
        -append 'console=ttyS0 panic=-1' \
        -device virtio-vga,max_outputs=1,xres=800,yres=600 \
        -device virtio-serial-pci \
        -chardev spiceport,id=webdav,name=org.spice-space.webdav.0 \
        -device virtserialport,chardev=webdav,name=org.spice-space.webdav.0 \
        -object secret,id=spice-password,file=/state/ticket \
        -spice "port=${WEBDAV_SPICE_PORT},addr=127.0.0.1,password-secret=spice-password,image-compression=auto_glz,streaming-video=off" \
        -display none \
        -serial stdio \
        -monitor none \
        -no-reboot >/dev/null

nohup podman logs --follow "${WEBDAV_CONTAINER}" > "${run_dir}/server.log" 2>&1 &
printf '%s\n' "$!" > "${WEBDAV_STATE}/log-follower.pid"

ready=false
for _ in $(seq 1 60); do
    if ss -ltn | grep -q "127.0.0.1:${WEBDAV_SPICE_PORT}" \
        && grep -q 'WEBDAV_GUEST_READY port=9843' "${run_dir}/server.log" 2>/dev/null; then
        ready=true
        break
    fi
    sleep 1
done
if [[ "${ready}" != true ]]; then
    echo "WebDAV endpoint did not become ready; inspect ${run_dir}/server.log" >&2
    exit 1
fi

echo "WebDAV endpoint ready on remote loopback 127.0.0.1:${WEBDAV_SPICE_PORT}."
echo "Read the temporary ticket with remote/ticket.sh; it is not printed here."
echo "Run evidence: ${run_dir}"
