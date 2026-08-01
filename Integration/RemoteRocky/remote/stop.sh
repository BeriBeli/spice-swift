#!/bin/bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

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
echo "Performance endpoint stopped; the temporary ticket was removed."
