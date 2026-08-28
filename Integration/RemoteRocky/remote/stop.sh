#!/bin/bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

acquire_lifecycle_lock
stop_interrupted=false
trap 'stop_interrupted=true' HUP INT TERM
if [[ "$(podman inspect --format '{{.State.Running}}' "${PERF_CONTAINER}" 2>/dev/null || true)" == true ]]; then
    stop_endpoint_locked
else
    podman rm --force "${PERF_CONTAINER}" >/dev/null 2>&1 || true
    discard_inactive_state_locked
fi
trap - HUP INT TERM
if [[ "${stop_interrupted}" == true ]]; then
    exit 1
fi
echo "Performance endpoint stopped; the temporary ticket was removed."
