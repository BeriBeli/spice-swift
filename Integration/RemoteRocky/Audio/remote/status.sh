#!/bin/bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_running
run_dir="$(current_run_dir)"
echo "state=running"
echo "container=${AUDIO_CONTAINER}"
echo "spice=127.0.0.1:${AUDIO_SPICE_PORT}"
echo "control=127.0.0.1:${AUDIO_CONTROL_PORT}"
echo "run_evidence=${run_dir}"
ss -ltn | grep -E "127.0.0.1:(${AUDIO_SPICE_PORT}|${AUDIO_CONTROL_PORT})"
"$(dirname "${BASH_SOURCE[0]}")/control.sh" status
