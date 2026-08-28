#!/bin/bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

acquire_lifecycle_lock
stop_interrupted=false
trap 'stop_interrupted=true' HUP INT TERM
teardown_status=0
if [[ "$(podman inspect --format '{{.State.Running}}' "${PERF_CONTAINER}" 2>/dev/null || true)" == true ]]; then
    stop_endpoint_locked || teardown_status=$?
else
    remove_inactive_endpoint_locked || teardown_status=$?
fi
trap - HUP INT TERM
if [[ "${stop_interrupted}" == true || "${teardown_status}" != 0 ]]; then
    exit 1
fi
echo "Performance endpoint stopped; the temporary ticket was removed."
