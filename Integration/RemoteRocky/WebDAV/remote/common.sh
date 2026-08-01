#!/bin/bash

set -euo pipefail

readonly WEBDAV_BASE="${SWIFTSPICE_WEBDAV_BASE:-${HOME}/swiftspice-remote-closure/webdav-live}"
readonly WEBDAV_ARTIFACTS="${WEBDAV_BASE}/artifacts"
readonly WEBDAV_STATE="${WEBDAV_BASE}/state"
readonly WEBDAV_LOGS="${WEBDAV_BASE}/logs"
readonly WEBDAV_CONTAINER="swiftspice-webdav-live-qemu"
readonly WEBDAV_IMAGE="localhost/swiftspice-qemu-x86:local"
readonly WEBDAV_SPICE_PORT="${SWIFTSPICE_WEBDAV_SPICE_PORT:-5945}"

mkdir -p "${WEBDAV_STATE}" "${WEBDAV_LOGS}"
chmod 0700 "${WEBDAV_BASE}" "${WEBDAV_STATE}" "${WEBDAV_LOGS}"

current_run_dir() {
    local run_id
    run_id="$(<"${WEBDAV_STATE}/current-run")"
    printf '%s/%s\n' "${WEBDAV_LOGS}" "${run_id}"
}

require_running() {
    if [[ "$(podman inspect --format '{{.State.Running}}' "${WEBDAV_CONTAINER}" 2>/dev/null || true)" != true ]]; then
        echo "WebDAV endpoint is not running." >&2
        return 1
    fi
}
