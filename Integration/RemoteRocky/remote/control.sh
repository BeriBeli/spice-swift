#!/bin/bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

action="${1:-}"
case "${action}" in
    start|reset|stop|status|diagnose-input)
        if [[ "$#" != 1 ]]; then
            echo "Usage: $0 {start|reset|stop|status|diagnose-input|arm ACTION_CLASS TOKEN}" >&2
            exit 2
        fi
        wire_command="${action}"
        ;;
    arm)
        if [[ "$#" != 3 \
            || ! "${2}" =~ ^(click|key|motion)$ \
            || ! "${3}" =~ ^[0-9a-f]{16}$ ]]; then
            echo "Usage: $0 arm {click|key|motion} TOKEN" >&2
            echo "TOKEN must be exactly 16 lowercase hexadecimal characters." >&2
            exit 2
        fi
        wire_command="arm action_class=${2} token=${3}"
        ;;
    *)
        echo "Usage: $0 {start|reset|stop|status|diagnose-input|arm ACTION_CLASS TOKEN}" >&2
        exit 2
        ;;
esac

require_running
run_dir="$(current_run_dir)"
printf '%s command=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${wire_command}" >> "${run_dir}/control.log"
podman exec "${PERF_CONTAINER}" \
    bash -c "printf '%s\\n' '${wire_command}' > /dev/tcp/127.0.0.1/${PERF_CONTROL_PORT}"
sleep 1
podman logs --tail 12 "${PERF_CONTAINER}"
