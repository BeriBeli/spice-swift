#!/bin/bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_running
run_dir="$(current_run_dir)"
echo "state=running"
echo "container=${PERF_CONTAINER}"
echo "spice=127.0.0.1:${PERF_SPICE_PORT}"
echo "control=127.0.0.1:${PERF_CONTROL_PORT}"
echo "resolution=1280x720"
echo "run_evidence=${run_dir}"
ss -ltn | grep -E "127.0.0.1:(${PERF_SPICE_PORT}|${PERF_CONTROL_PORT})"
podman logs --tail 12 "${PERF_CONTAINER}"
