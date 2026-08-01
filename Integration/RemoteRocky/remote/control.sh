#!/bin/bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

action="${1:-}"
case "${action}" in
    start|reset|stop|status) ;;
    *)
        echo "Usage: $0 {start|reset|stop|status}" >&2
        exit 2
        ;;
esac

require_running
run_dir="$(current_run_dir)"
printf '%s action=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${action}" >> "${run_dir}/control.log"
podman exec "${PERF_CONTAINER}" \
    bash -c "printf '%s\\n' '${action}' > /dev/tcp/127.0.0.1/${PERF_CONTROL_PORT}"
sleep 1
podman logs --tail 12 "${PERF_CONTAINER}"
