#!/bin/bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

run_dir="$(current_run_dir 2>/dev/null || true)"
if [[ -n "${run_dir}" ]]; then
    podman logs "${AUDIO_CONTAINER}" > "${run_dir}/server-final.log" 2>&1 || true
fi
podman stop --time 10 "${AUDIO_CONTAINER}" >/dev/null 2>&1 || true
podman rm --force "${AUDIO_CONTAINER}" >/dev/null 2>&1 || true
if [[ -f "${AUDIO_STATE}/log-follower.pid" ]]; then
    kill "$(<"${AUDIO_STATE}/log-follower.pid")" 2>/dev/null || true
fi
rm -f \
    "${AUDIO_STATE}/ticket" \
    "${AUDIO_STATE}/current-run" \
    "${AUDIO_STATE}/log-follower.pid"
echo "Audio endpoint stopped; the temporary ticket was removed."
