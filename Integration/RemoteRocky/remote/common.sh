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

live_identity_count=0
for identity_presence in \
    "${SWIFTSPICE_LIVE_CAMPAIGN_ID+x}" \
    "${SWIFTSPICE_LIVE_LOGICAL_RUN_ID+x}" \
    "${SWIFTSPICE_LIVE_VERSION+x}" \
    "${SWIFTSPICE_LIVE_CLUSTER_ID+x}" \
    "${SWIFTSPICE_LIVE_RUN_SEQUENCE+x}" \
    "${SWIFTSPICE_LIVE_EXECUTION_CONTRACT_DIGEST+x}"; do
    if [[ "${identity_presence}" == x ]]; then
        live_identity_count=$((live_identity_count + 1))
    fi
done
if [[ "${live_identity_count}" != 0 ]]; then
    if [[ "${live_identity_count}" != 6 || "${override_count}" != 5 \
        || ! "${SWIFTSPICE_LIVE_CAMPAIGN_ID-}" =~ ^[0-9a-f]{16}$ \
        || ! "${SWIFTSPICE_LIVE_LOGICAL_RUN_ID-}" =~ ^[0-9a-f]{16}$ \
        || ! "${SWIFTSPICE_LIVE_VERSION-}" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ \
        || ! "${SWIFTSPICE_LIVE_CLUSTER_ID-}" =~ ^[0-9a-f]{16}$ \
        || ! "${SWIFTSPICE_LIVE_RUN_SEQUENCE-}" =~ ^[1-9][0-9]*$ \
        || ! "${SWIFTSPICE_LIVE_EXECUTION_CONTRACT_DIGEST-}" =~ ^[0-9a-f]{64}$ ]]; then
        echo "Live identity requires six canonical fields and explicit endpoint overrides." >&2
        exit 2
    fi
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
    if [[ "${live_identity_count}" != 0 \
        && ! "${run_id}" =~ ^[0-9]{8}T[0-9]{6}Z\.[A-Za-z0-9]{6}$ ]]; then
        echo "Live evidence must name one canonical run directory." >&2
        return 1
    fi
    printf '%s/%s\n' "${PERF_LOGS}" "${run_id}"
}

# The six lines are a canonical projection of configuration.txt. Keeping
# them in one existing run record avoids a second identity owner or journal.
emit_live_identity() {
    [[ "${live_identity_count}" != 0 ]] || return 0
    printf 'campaign_id=%s\nlogical_run_id=%s\nversion=%s\ncluster_id=%s\nrun_sequence=%s\nexecution_contract_digest=%s\n' \
        "${SWIFTSPICE_LIVE_CAMPAIGN_ID}" \
        "${SWIFTSPICE_LIVE_LOGICAL_RUN_ID}" \
        "${SWIFTSPICE_LIVE_VERSION}" \
        "${SWIFTSPICE_LIVE_CLUSTER_ID}" \
        "${SWIFTSPICE_LIVE_RUN_SEQUENCE}" \
        "${SWIFTSPICE_LIVE_EXECUTION_CONTRACT_DIGEST}"
}

# Call under the lifecycle lock, before publishing status or stopping a run.
# Compare stored evidence with the caller's expectation; never relabel it.
read_live_identity() {
    [[ "${live_identity_count}" != 0 ]] || return 0
    local recorded endpoint
    if ! endpoint="$(LC_ALL=C grep -E '^(spice_listen|control_listen|container|image)=' \
        "$1/configuration.txt")" \
        || [[ "${endpoint}" != "$(printf 'spice_listen=127.0.0.1:%s\ncontrol_listen=127.0.0.1:%s\ncontainer=%s\nimage=%s\n' \
            "${PERF_SPICE_PORT}" "${PERF_CONTROL_PORT}" "${PERF_CONTAINER}" "${PERF_IMAGE}")" ]] \
        || ! recorded="$(LC_ALL=C grep -E \
        '^(campaign_id|logical_run_id|version|cluster_id|run_sequence|execution_contract_digest)=' \
        "$1/configuration.txt")" \
        || [[ "${recorded}" != "$(emit_live_identity)" ]]; then
        echo "Recorded live identity is missing, malformed, or mismatched." >&2
        return 1
    fi
    printf '%s\n' "${recorded}"
}

# The configured name can be reused outside this lifecycle. Bind later
# operations to the recorded ID. Only teardown allows an absent name so it
# can still retire the recorded ID and state after a rename or removal.
read_live_container_id() {
    local recorded observed
    if ! recorded="$(cat "$1/container-id.txt")" \
        || [[ ! "${recorded}" =~ ^[0-9a-f]{64}$ ]]; then
        echo "Recorded live container ID is missing or malformed." >&2
        return 1
    fi
    if observed="$(podman inspect --format '{{.Id}}' "${PERF_CONTAINER}" 2>/dev/null)"; then
        if [[ "${observed}" != "${recorded}" ]]; then
            echo "Configured container no longer belongs to the recorded run." >&2
            return 1
        fi
    elif [[ "${2:-}" != allow-absent ]] || ! configured_container_absence_is_confirmed; then
        echo "Cannot verify the recorded live container." >&2
        return 1
    fi
    printf '%s\n' "${recorded}"
}

require_running() {
    if [[ "$(podman inspect --format '{{.State.Running}}' "${1:-${PERF_CONTAINER}}" 2>/dev/null || true)" != true ]]; then
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
    podman container exists "${1:-${PERF_CONTAINER}}" >/dev/null 2>&1 || status=$?
    [[ "${status}" == 1 ]]
}

teardown_failed() {
    echo "Performance endpoint teardown failed; active state was preserved." >&2
    return 1
}

# The caller must hold PERF_LIFECYCLE_LOCK and must have observed that the
# target container is not running. The configured name must also be absent
# before stale active state is discarded.
remove_inactive_endpoint_locked() {
    local container_target="${1:-${PERF_CONTAINER}}"
    podman rm --force "${container_target}" >/dev/null 2>&1 || true
    if ! configured_container_absence_is_confirmed "${container_target}" \
        || ! configured_container_absence_is_confirmed; then
        teardown_failed
        return 1
    fi
    discard_inactive_state_locked
}

# The caller must hold PERF_LIFECYCLE_LOCK. Keeping cleanup in-process lets a
# failed start retain the lock until its container and active state are gone.
stop_endpoint_locked() {
    local run_dir container_target="${1:-${PERF_CONTAINER}}"
    run_dir="$(current_run_dir 2>/dev/null || true)"
    if [[ -n "${run_dir}" ]]; then
        podman logs "${container_target}" > "${run_dir}/server-final.log" 2>&1 || true
    fi
    podman stop --time 10 "${container_target}" >/dev/null 2>&1 || true
    podman rm --force "${container_target}" >/dev/null 2>&1 || true
    if ! configured_container_absence_is_confirmed "${container_target}" \
        || ! configured_container_absence_is_confirmed; then
        teardown_failed
        return 1
    fi
    discard_inactive_state_locked
}
