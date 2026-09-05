#!/bin/bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

acquire_lifecycle_lock
container_target="${PERF_CONTAINER}"
if [[ "${live_identity_count}" != 0 ]]; then
    if [[ -e "${PERF_STATE}/current-run" ]]; then
        run_dir="$(current_run_dir)"
        read_live_identity "${run_dir}" >/dev/null
        container_target="$(read_live_container_id "${run_dir}")"
    elif ! configured_container_absence_is_confirmed; then
        echo "Cannot stop a live endpoint without recorded ownership." >&2
        exit 1
    else
        discard_inactive_state_locked
        echo "Performance endpoint stopped; the temporary ticket was removed."
        exit 0
    fi
fi
stop_interrupted=false
trap 'stop_interrupted=true' HUP INT TERM
teardown_status=0
if [[ "$(podman inspect --format '{{.State.Running}}' "${container_target}" 2>/dev/null || true)" == true ]]; then
    stop_endpoint_locked "${container_target}" || teardown_status=$?
else
    remove_inactive_endpoint_locked "${container_target}" || teardown_status=$?
fi
trap - HUP INT TERM
if [[ "${stop_interrupted}" == true || "${teardown_status}" != 0 ]]; then
    exit 1
fi
echo "Performance endpoint stopped; the temporary ticket was removed."
