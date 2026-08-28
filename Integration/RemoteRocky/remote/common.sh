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
readonly PERF_LIFECYCLE_LOCK="${PERF_STATE}/lifecycle.lock"

mkdir -p "${PERF_STATE}" "${PERF_LOGS}"
chmod 0700 "${PERF_BASE}" "${PERF_STATE}" "${PERF_LOGS}"

enter_lifecycle_lock() {
    if [[ "${SWIFTSPICE_LIFECYCLE_LOCK_HELD:-}" == 1 ]]; then
        return
    fi
    exec env SWIFTSPICE_LIFECYCLE_LOCK_HELD=1 \
        flock --exclusive --close "${PERF_LIFECYCLE_LOCK}" "$0" "$@"
}

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

loopback_port_is_listening() {
    local port="$1"
    ss -ltnH | awk -v endpoint="127.0.0.1:${port}" '
        $4 == endpoint { found = 1 }
        END { exit(found ? 0 : 1) }
    '
}

# The caller must hold PERF_LIFECYCLE_LOCK. Keeping cleanup in-process lets a
# failed start retain the lock until its container and active state are gone.
stop_endpoint_locked() {
    local run_dir
    run_dir="$(current_run_dir 2>/dev/null || true)"
    if [[ -n "${run_dir}" ]]; then
        podman logs "${PERF_CONTAINER}" > "${run_dir}/server-final.log" 2>&1 || true
    fi
    podman stop --time 10 "${PERF_CONTAINER}" >/dev/null 2>&1 || true
    podman rm --force "${PERF_CONTAINER}" >/dev/null 2>&1 || true
    if [[ -f "${PERF_STATE}/log-follower.pid" ]]; then
        kill "$(<"${PERF_STATE}/log-follower.pid")" 2>/dev/null || true
    fi
    rm -f \
        "${PERF_STATE}/ticket" \
        "${PERF_STATE}/current-run" \
        "${PERF_STATE}/log-follower.pid" \
        "${PERF_STATE}/round-start" \
        "${PERF_STATE}/round-id"
}
