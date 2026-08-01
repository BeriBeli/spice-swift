#!/bin/bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

if [[ "$(podman inspect --format '{{.State.Running}}' "${AUDIO_CONTAINER}" 2>/dev/null || true)" == true ]]; then
    echo "Audio endpoint is already running."
    exec "$(dirname "${BASH_SOURCE[0]}")/status.sh"
fi

podman rm --force "${AUDIO_CONTAINER}" >/dev/null 2>&1 || true
if [[ ! -r "${AUDIO_ARTIFACTS}/vmlinuz-virt" \
    || ! -r "${AUDIO_ARTIFACTS}/audio-initramfs.cpio.gz" ]]; then
    echo "Audio guest artifacts are missing." >&2
    exit 1
fi
run_id="$(date -u +%Y%m%dT%H%M%SZ)"
run_dir="${AUDIO_LOGS}/${run_id}"
mkdir -p "${run_dir}"
chmod 0700 "${run_dir}"

ticket="$(openssl rand -hex 24)"
umask 077
printf '%s' "${ticket}" > "${AUDIO_STATE}/ticket"
printf '%s\n' "${run_id}" > "${AUDIO_STATE}/current-run"

cat > "${run_dir}/configuration.txt" <<EOF
run_id=${run_id}
spice_listen=127.0.0.1:${AUDIO_SPICE_PORT}
control_listen=127.0.0.1:${AUDIO_CONTROL_PORT}
audio_backend=spice
audio_controller=ich9-intel-hda
audio_codec=hda-duplex
playback_format=s16le,48000,2
record_format=s16le,48000,2
playback_compression=on
image_compression=off
streaming_video=off
EOF
podman run --rm "${AUDIO_IMAGE}" qemu-system-x86_64 --version > "${run_dir}/versions.txt"
podman run --rm "${AUDIO_IMAGE}" dpkg-query -W libspice-server1 qemu-system-x86 qemu-system-modules-spice \
    >> "${run_dir}/versions.txt"

podman run --detach \
    --name "${AUDIO_CONTAINER}" \
    --device /dev/kvm \
    --network host \
    --env G_MESSAGES_DEBUG=all \
    --volume "${AUDIO_ARTIFACTS}:/guest:ro,Z" \
    --volume "${AUDIO_STATE}:/state:ro,Z" \
    "${AUDIO_IMAGE}" \
    qemu-system-x86_64 \
        -nodefaults \
        -no-user-config \
        -machine q35,accel=kvm \
        -cpu host \
        -smp 2 \
        -m 1024 \
        -kernel /guest/vmlinuz-virt \
        -initrd /guest/audio-initramfs.cpio.gz \
        -append 'console=ttyS0 panic=-1' \
        -device virtio-vga,max_outputs=1,xres=800,yres=600 \
        -device virtio-serial-pci \
        -chardev "socket,id=audio-control,host=127.0.0.1,port=${AUDIO_CONTROL_PORT},server=on,wait=off" \
        -device virtserialport,chardev=audio-control,name=org.swiftspice.audio.control \
        -audiodev spice,id=audio0 \
        -device ich9-intel-hda \
        -device hda-duplex,audiodev=audio0 \
        -object secret,id=spice-password,file=/state/ticket \
        -spice "port=${AUDIO_SPICE_PORT},addr=127.0.0.1,password-secret=spice-password,image-compression=off,streaming-video=off,playback-compression=on" \
        -display none \
        -serial stdio \
        -monitor none \
        -no-reboot >/dev/null

nohup podman logs --follow "${AUDIO_CONTAINER}" > "${run_dir}/server.log" 2>&1 &
printf '%s\n' "$!" > "${AUDIO_STATE}/log-follower.pid"

ready=false
for _ in $(seq 1 60); do
    if ss -ltn | grep -q "127.0.0.1:${AUDIO_SPICE_PORT}" \
        && grep -q 'AUDIO_READY playback=hw:0,0 record=hw:0,0 rate=48000 channels=2' "${run_dir}/server.log" 2>/dev/null; then
        ready=true
        break
    fi
    sleep 1
done
if [[ "${ready}" != true ]]; then
    echo "Audio endpoint did not become ready; inspect ${run_dir}/server.log" >&2
    exit 1
fi

echo "Audio endpoint ready on remote loopback 127.0.0.1:${AUDIO_SPICE_PORT}."
echo "Read the temporary ticket with remote/ticket.sh; it is not printed here."
echo "Run evidence: ${run_dir}"
