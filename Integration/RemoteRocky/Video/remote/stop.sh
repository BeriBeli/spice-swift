#!/bin/bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

run_dir="$(current_run_dir 2>/dev/null || true)"
if [[ -n "${run_dir}" ]]; then
    podman logs "${VIDEO_CONTAINER}" > "${run_dir}/server-final.log" 2>&1 || true
fi
podman stop --time 10 "${VIDEO_CONTAINER}" >/dev/null 2>&1 || true
podman rm --force "${VIDEO_CONTAINER}" >/dev/null 2>&1 || true
if [[ -f "${VIDEO_STATE}/log-follower.pid" ]]; then
    kill "$(<"${VIDEO_STATE}/log-follower.pid")" 2>/dev/null || true
fi
rm -f "${VIDEO_STATE}/ticket" "${VIDEO_STATE}/current-run" "${VIDEO_STATE}/log-follower.pid"
echo "Advanced-video endpoint stopped and its temporary ticket was removed."
