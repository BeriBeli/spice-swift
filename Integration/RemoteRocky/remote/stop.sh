#!/bin/bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

acquire_lifecycle_lock
stop_interrupted=false
trap 'stop_interrupted=true' HUP INT TERM
stop_endpoint_locked
trap - HUP INT TERM
if [[ "${stop_interrupted}" == true ]]; then
    exit 1
fi
echo "Performance endpoint stopped; the temporary ticket was removed."
