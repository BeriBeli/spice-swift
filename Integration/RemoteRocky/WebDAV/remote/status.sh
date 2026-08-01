#!/bin/bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_running
run_dir="$(current_run_dir)"
echo "state=running"
echo "container=${WEBDAV_CONTAINER}"
echo "spice=127.0.0.1:${WEBDAV_SPICE_PORT}"
echo "run_evidence=${run_dir}"
ss -ltn | grep "127.0.0.1:${WEBDAV_SPICE_PORT}"
podman logs --tail 20 "${WEBDAV_CONTAINER}"
