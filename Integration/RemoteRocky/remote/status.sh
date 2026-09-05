#!/bin/bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

acquire_lifecycle_lock
run_dir="$(current_run_dir)"
identity="$(read_live_identity "${run_dir}")"
container_target="${PERF_CONTAINER}"
if [[ -n "${identity}" ]]; then
    container_target="$(read_live_container_id "${run_dir}")"
fi
require_running "${container_target}"
if [[ -n "${identity}" ]]; then
    printf '%s\n' "${identity}"
fi
echo "state=running"
echo "container=${PERF_CONTAINER}"
echo "spice=127.0.0.1:${PERF_SPICE_PORT}"
echo "control=127.0.0.1:${PERF_CONTROL_PORT}"
echo "resolution=1280x720"
echo "run_evidence=${run_dir}"
port_status=0
if loopback_port_is_listening "${PERF_SPICE_PORT}"; then
    echo "spice_listener=ready"
else
    echo "spice_listener=missing" >&2
    port_status=1
fi
if loopback_port_is_listening "${PERF_CONTROL_PORT}"; then
    echo "control_listener=ready"
else
    echo "control_listener=missing" >&2
    port_status=1
fi
podman logs --tail 12 "${container_target}" 9>&-
exit "${port_status}"
