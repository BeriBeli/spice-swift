#!/bin/bash

set -euo pipefail

readonly VIDEO_BASE="${SWIFTSPICE_VIDEO_BASE:-${HOME}/swiftspice-remote-closure/video-live}"
readonly VIDEO_GUEST_ARTIFACTS="${SWIFTSPICE_VIDEO_GUEST_ARTIFACTS:-${VIDEO_BASE}/artifacts}"
readonly VIDEO_STATE="${VIDEO_BASE}/state"
readonly VIDEO_LOGS="${VIDEO_BASE}/logs"
readonly VIDEO_CONTAINER="swiftspice-video-live-qemu"
readonly VIDEO_IMAGE="localhost/swiftspice-qemu-h264-x86:local"
readonly VIDEO_SPICE_PORT="${SWIFTSPICE_VIDEO_SPICE_PORT:-5955}"
readonly VIDEO_CONTROL_PORT="${SWIFTSPICE_VIDEO_CONTROL_PORT:-5956}"

mkdir -p "${VIDEO_STATE}" "${VIDEO_LOGS}"
chmod 0700 "${VIDEO_BASE}" "${VIDEO_STATE}" "${VIDEO_LOGS}"

current_run_dir() {
    if [[ ! -f "${VIDEO_STATE}/current-run" ]]; then
        echo "No active advanced-video run." >&2
        return 1
    fi
    local run_id
    run_id="$(<"${VIDEO_STATE}/current-run")"
    printf '%s/%s\n' "${VIDEO_LOGS}" "${run_id}"
}

require_running() {
    if [[ "$(podman inspect --format '{{.State.Running}}' "${VIDEO_CONTAINER}" 2>/dev/null || true)" != true ]]; then
        echo "Advanced-video endpoint is not running." >&2
        return 1
    fi
}
