#!/bin/bash

set -euo pipefail

readonly PERF_BASE="${SWIFTSPICE_PERF_BASE:-${HOME}/swiftspice-remote-closure/perf-ab}"
readonly PERF_ARTIFACTS="${PERF_BASE}/artifacts"
readonly PERF_STATE="${PERF_BASE}/state"
readonly PERF_LOGS="${PERF_BASE}/logs"
readonly PERF_CONTAINER="swiftspice-perf-ab-qemu"
readonly PERF_IMAGE="localhost/swiftspice-qemu-x86:local"
readonly PERF_SPICE_PORT="${SWIFTSPICE_PERF_SPICE_PORT:-5935}"
readonly PERF_CONTROL_PORT="${SWIFTSPICE_PERF_CONTROL_PORT:-5936}"

mkdir -p "${PERF_STATE}" "${PERF_LOGS}"
chmod 0700 "${PERF_BASE}" "${PERF_STATE}" "${PERF_LOGS}"

current_run_dir() {
    if [[ ! -f "${PERF_STATE}/current-run" ]]; then
        echo "No active performance run." >&2
        return 1
    fi
    local run_id
    run_id="$(<"${PERF_STATE}/current-run")"
    printf '%s/%s\n' "${PERF_LOGS}" "${run_id}"
}

require_running() {
    if [[ "$(podman inspect --format '{{.State.Running}}' "${PERF_CONTAINER}" 2>/dev/null || true)" != true ]]; then
        echo "Performance endpoint is not running." >&2
        return 1
    fi
}
