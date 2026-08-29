#!/bin/bash

set -euo pipefail

override_count=0
for override_presence in \
    "${SWIFTSPICE_PERF_BASE+x}" \
    "${SWIFTSPICE_PERF_CONTAINER+x}" \
    "${SWIFTSPICE_PERF_IMAGE+x}" \
    "${SWIFTSPICE_PERF_SPICE_PORT+x}" \
    "${SWIFTSPICE_PERF_CONTROL_PORT+x}"; do
    if [[ "${override_presence}" == x ]]; then
        override_count=$((override_count + 1))
    fi
done
if [[ "${override_count}" != 0 && "${override_count}" != 5 ]]; then
    echo "SWIFTSPICE_PERF_* overrides must be set together." >&2
    exit 2
fi

if [[ "${override_count}" == 5 ]]; then
    readonly PERF_BASE="${SWIFTSPICE_PERF_BASE}"
    readonly PERF_CONTAINER="${SWIFTSPICE_PERF_CONTAINER}"
    readonly PERF_IMAGE="${SWIFTSPICE_PERF_IMAGE}"
    readonly PERF_SPICE_PORT="${SWIFTSPICE_PERF_SPICE_PORT}"
    readonly PERF_CONTROL_PORT="${SWIFTSPICE_PERF_CONTROL_PORT}"
else
    readonly PERF_BASE="${HOME}/swiftspice-remote-closure/perf-ab"
    readonly PERF_CONTAINER="swiftspice-perf-ab-qemu"
    readonly PERF_IMAGE="localhost/swiftspice-qemu-x86:local"
    readonly PERF_SPICE_PORT=5935
    readonly PERF_CONTROL_PORT=5936
fi
readonly PERF_ARTIFACTS="${PERF_BASE}/artifacts"
readonly PERF_STATE="${PERF_BASE}/state"
readonly PERF_LOGS="${PERF_BASE}/logs"
readonly PERF_LIFECYCLE_LOCK="${PERF_STATE}/lifecycle.lock"

if [[ ! "${PERF_BASE}" =~ ^/[^[:cntrl:]]+$ \
    || "${PERF_BASE}" == / \
    || "${PERF_BASE}" == */ \
    || "${PERF_BASE}" == *"//"* \
    || "${PERF_BASE}" == *'/../'* \
    || "${PERF_BASE}" == */.. \
    || "${PERF_BASE}" == *'/./'* \
    || "${PERF_BASE}" == */. ]]; then
    echo "SWIFTSPICE_PERF_BASE is invalid." >&2
    exit 2
fi
if [[ ! "${PERF_CONTAINER}" =~ ^[a-z0-9][a-z0-9_.-]{0,127}$ ]]; then
    echo "SWIFTSPICE_PERF_CONTAINER is invalid." >&2
    exit 2
fi
if [[ ! "${PERF_IMAGE}" =~ ^[a-z0-9][a-z0-9._-]*(/[a-z0-9][a-z0-9._-]*)*(:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})?$ ]]; then
    echo "SWIFTSPICE_PERF_IMAGE is invalid." >&2
    exit 2
fi
if [[ ! "${PERF_SPICE_PORT}" =~ ^[1-9][0-9]{0,4}$ ]] \
    || ((10#${PERF_SPICE_PORT} < 1024 || 10#${PERF_SPICE_PORT} > 65535)); then
    echo "SWIFTSPICE_PERF_SPICE_PORT is invalid." >&2
    exit 2
fi
if [[ ! "${PERF_CONTROL_PORT}" =~ ^[1-9][0-9]{0,4}$ ]] \
    || ((10#${PERF_CONTROL_PORT} < 1024 || 10#${PERF_CONTROL_PORT} > 65535)) \
    || [[ "${PERF_CONTROL_PORT}" == "${PERF_SPICE_PORT}" ]]; then
    echo "SWIFTSPICE_PERF_CONTROL_PORT is invalid." >&2
    exit 2
fi

mkdir -p "${PERF_STATE}" "${PERF_LOGS}"
chmod 0700 "${PERF_BASE}" "${PERF_STATE}" "${PERF_LOGS}"

acquire_lifecycle_lock() {
    exec 9>"${PERF_LIFECYCLE_LOCK}"
    flock --exclusive 9
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

# The caller must hold PERF_LIFECYCLE_LOCK and must already have established
# that the configured container is not running. A persisted PID may have been reused
# by the OS, so inactive-state discard never signals it.
discard_inactive_state_locked() {
    rm -f \
        "${PERF_STATE}/ticket" \
        "${PERF_STATE}/current-run" \
        "${PERF_STATE}/log-follower.pid" \
        "${PERF_STATE}/round-start" \
        "${PERF_STATE}/round-id"
}

configured_container_absence_is_confirmed() {
    local status=0
    podman container exists "${PERF_CONTAINER}" >/dev/null 2>&1 || status=$?
    [[ "${status}" == 1 ]]
}

teardown_failed() {
    echo "Performance endpoint teardown failed; active state was preserved." >&2
    return 1
}

# The caller must hold PERF_LIFECYCLE_LOCK and must have observed that the
# configured container is not running. Removal is still confirmed before stale
# active state is discarded.
remove_inactive_endpoint_locked() {
    podman rm --force "${PERF_CONTAINER}" >/dev/null 2>&1 || true
    if ! configured_container_absence_is_confirmed; then
        teardown_failed
        return 1
    fi
    discard_inactive_state_locked
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
    if ! configured_container_absence_is_confirmed; then
        teardown_failed
        return 1
    fi
    discard_inactive_state_locked
}
