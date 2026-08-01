#!/bin/bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_running
run_dir="$(current_run_dir)"
echo "state=running"
echo "container=${VIDEO_CONTAINER}"
echo "spice=127.0.0.1:${VIDEO_SPICE_PORT}"
echo "control=127.0.0.1:${VIDEO_CONTROL_PORT}"
echo "run_evidence=${run_dir}"
ss -ltn | grep -E "127.0.0.1:(${VIDEO_SPICE_PORT}|${VIDEO_CONTROL_PORT})"
grep -E 'STREAM_AGENT|PERF_(READY|LOAD|STATUS)' "${run_dir}/server.log" | tail -n 30 || true
