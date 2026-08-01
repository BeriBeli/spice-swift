#!/bin/bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

run_dir="$(current_run_dir 2>/dev/null || true)"
if [[ -n "${run_dir}" ]]; then
    podman logs "${WEBDAV_CONTAINER}" > "${run_dir}/server-final.log" 2>&1 || true
fi
podman stop --time 10 "${WEBDAV_CONTAINER}" >/dev/null 2>&1 || true
podman rm --force "${WEBDAV_CONTAINER}" >/dev/null 2>&1 || true
if [[ -f "${WEBDAV_STATE}/log-follower.pid" ]]; then
    kill "$(<"${WEBDAV_STATE}/log-follower.pid")" 2>/dev/null || true
fi
rm -f "${WEBDAV_STATE}/ticket" "${WEBDAV_STATE}/current-run" "${WEBDAV_STATE}/log-follower.pid"
echo "WebDAV endpoint stopped and its temporary ticket was removed."
