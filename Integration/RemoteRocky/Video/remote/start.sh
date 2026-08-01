#!/bin/bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

if [[ "$(podman inspect --format '{{.State.Running}}' "${VIDEO_CONTAINER}" 2>/dev/null || true)" == true ]]; then
    echo "Advanced-video endpoint is already running."
    exec "$(dirname "${BASH_SOURCE[0]}")/status.sh"
fi

podman rm --force "${VIDEO_CONTAINER}" >/dev/null 2>&1 || true
if [[ ! -r "${VIDEO_GUEST_ARTIFACTS}/vmlinuz-virt" \
    || ! -r "${VIDEO_GUEST_ARTIFACTS}/perf-initramfs.cpio.gz" ]]; then
    echo "Performance guest artifacts are missing." >&2
    exit 1
fi
run_id="$(date -u +%Y%m%dT%H%M%SZ)"
run_dir="${VIDEO_LOGS}/${run_id}"
mkdir -p "${run_dir}"
chmod 0700 "${run_dir}"

ticket="$(openssl rand -hex 24)"
umask 077
printf '%s' "${ticket}" > "${VIDEO_STATE}/ticket"
printf '%s\n' "${run_id}" > "${VIDEO_STATE}/current-run"

cat > "${run_dir}/configuration.txt" <<EOF
run_id=${run_id}
resolution=1280x720
spice_listen=127.0.0.1:${VIDEO_SPICE_PORT}
control_listen=127.0.0.1:${VIDEO_CONTROL_PORT}
streaming_video=off
target_client_codec_policies=h264,mjpeg|h265,mjpeg
stream_source=guest_stream_device
h264_profile=constrained-baseline
h264_pixel_format=yuv420p
h265_profile=main
h265_pixel_format=yuv420p
image_compression=off
EOF
podman run --rm "${VIDEO_IMAGE}" qemu-system-x86_64 --version > "${run_dir}/versions.txt"
podman run --rm "${VIDEO_IMAGE}" dpkg-query -W libspice-server1 qemu-system-x86 qemu-system-modules-spice \
    >> "${run_dir}/versions.txt"
podman run --rm "${VIDEO_IMAGE}" sh -c \
    'cat /usr/local/share/swiftspice/stream-h264-metadata.txt; cat /usr/local/share/swiftspice/stream-h265-metadata.txt' \
    > "${run_dir}/stream-metadata.txt"

podman run --detach \
    --name "${VIDEO_CONTAINER}" \
    --device /dev/kvm \
    --network host \
    --env G_MESSAGES_DEBUG=all \
    --volume "${VIDEO_GUEST_ARTIFACTS}:/guest:ro,Z" \
    --volume "${VIDEO_STATE}:/state:ro,Z" \
    "${VIDEO_IMAGE}" \
    qemu-system-x86_64 \
        -nodefaults \
        -no-user-config \
        -machine q35,accel=kvm \
        -cpu host \
        -smp 2 \
        -m 1536 \
        -kernel /guest/vmlinuz-virt \
        -initrd /guest/perf-initramfs.cpio.gz \
        -append 'console=ttyS0 panic=-1' \
        -device virtio-vga,max_outputs=1,xres=1280,yres=720 \
        -device virtio-keyboard-pci \
        -device virtio-mouse-pci \
        -device virtio-serial-pci \
        -chardev spicevmc,id=vdagent,name=vdagent \
        -device virtserialport,chardev=vdagent,name=com.redhat.spice.0 \
        -chardev spiceport,id=video-stream,name=org.spice-space.stream.0 \
        -device virtserialport,chardev=video-stream,name=org.spice-space.stream.0 \
        -chardev "socket,id=video-control,host=127.0.0.1,port=${VIDEO_CONTROL_PORT},server=on,wait=off" \
        -device virtserialport,chardev=video-control,name=org.swiftspice.perf.control \
        -object secret,id=spice-password,file=/state/ticket \
        -spice "port=${VIDEO_SPICE_PORT},addr=127.0.0.1,password-secret=spice-password,image-compression=off,streaming-video=off,playback-compression=on" \
        -display none \
        -serial stdio \
        -monitor none \
        -no-reboot >/dev/null

nohup podman logs --follow "${VIDEO_CONTAINER}" > "${run_dir}/server.log" 2>&1 &
printf '%s\n' "$!" > "${VIDEO_STATE}/log-follower.pid"

ready=false
for _ in $(seq 1 60); do
    if ss -ltn | grep -q "127.0.0.1:${VIDEO_SPICE_PORT}" \
        && grep -q 'PERF_READY resolution=1280x720 stream_device=h264,h265' "${run_dir}/server.log" 2>/dev/null \
        && grep -q 'STREAM_AGENT ready codecs=h264,h265' "${run_dir}/server.log" 2>/dev/null; then
        ready=true
        break
    fi
    sleep 1
done
if [[ "${ready}" != true ]]; then
    echo "Advanced-video endpoint did not become ready; inspect ${run_dir}/server.log" >&2
    exit 1
fi

echo "Advanced-video endpoint ready on remote loopback 127.0.0.1:${VIDEO_SPICE_PORT}."
echo "Read the temporary ticket with remote/ticket.sh; it is not printed here."
echo "Run evidence: ${run_dir}"
