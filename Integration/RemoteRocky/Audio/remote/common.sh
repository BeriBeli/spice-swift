#!/bin/bash

set -euo pipefail

readonly AUDIO_BASE="${SWIFTSPICE_AUDIO_BASE:-${HOME}/swiftspice-remote-closure/audio-live}"
readonly AUDIO_ARTIFACTS="${AUDIO_BASE}/artifacts"
readonly AUDIO_STATE="${AUDIO_BASE}/state"
readonly AUDIO_LOGS="${AUDIO_BASE}/logs"
readonly AUDIO_CONTAINER="swiftspice-audio-live-qemu"
readonly AUDIO_IMAGE="localhost/swiftspice-qemu-x86:local"
readonly AUDIO_SPICE_PORT="${SWIFTSPICE_AUDIO_SPICE_PORT:-5965}"
readonly AUDIO_CONTROL_PORT="${SWIFTSPICE_AUDIO_CONTROL_PORT:-5966}"

mkdir -p "${AUDIO_STATE}" "${AUDIO_LOGS}"
chmod 0700 "${AUDIO_BASE}" "${AUDIO_STATE}" "${AUDIO_LOGS}"

current_run_dir() {
    if [[ ! -f "${AUDIO_STATE}/current-run" ]]; then
        echo "No active audio run." >&2
        return 1
    fi
    local run_id
    run_id="$(<"${AUDIO_STATE}/current-run")"
    printf '%s/%s\n' "${AUDIO_LOGS}" "${run_id}"
}

require_running() {
    if [[ "$(podman inspect --format '{{.State.Running}}' "${AUDIO_CONTAINER}" 2>/dev/null || true)" != true ]]; then
        echo "Audio endpoint is not running." >&2
        return 1
    fi
}
