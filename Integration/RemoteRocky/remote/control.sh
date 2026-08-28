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

diagnostic_log_offset=
if [[ "${action}" == diagnose-input ]]; then
    # Serialize diagnostics so the first complete block after this byte
    # boundary belongs to this invocation, even when server.log is appended by
    # the persistent Podman log follower.
    exec 8>"${PERF_STATE}/input-diagnostic.lock"
    flock --exclusive 8
    server_log="${run_dir}/server.log"
    if [[ -f "${server_log}" ]]; then
        diagnostic_log_offset="$(wc -c < "${server_log}")"
    else
        diagnostic_log_offset=0
    fi
fi

printf '%s command=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${wire_command}" >> "${run_dir}/control.log"
podman exec "${PERF_CONTAINER}" \
    bash -c "printf '%s\\n' '${wire_command}' > /dev/tcp/127.0.0.1/${PERF_CONTROL_PORT}"

if [[ "${action}" == diagnose-input ]]; then
    for _ in {1..100}; do
        diagnostic_block="$(
            tail -c "+$((diagnostic_log_offset + 1))" "${server_log}" 2>/dev/null |
                awk '
                    {
                        line = $0
                        sub(/\r$/, "", line)
                    }
                    line == "PERF_INPUT_DIAGNOSTIC_BEGIN" {
                        if (!capturing) {
                            capturing = 1
                            block = line ORS
                            next
                        }
                    }
                    capturing {
                        block = block line ORS
                        if (line == "PERF_INPUT_DIAGNOSTIC_END") {
                            printf "%s", block
                            found = 1
                            exit
                        }
                    }
                    END { exit(found ? 0 : 1) }
                '
        )" || true
        diagnostic_first_line="${diagnostic_block%%$'\n'*}"
        diagnostic_last_line="${diagnostic_block##*$'\n'}"
        if [[ "${diagnostic_block}" == *$'\n'* \
            && "${diagnostic_first_line}" == PERF_INPUT_DIAGNOSTIC_BEGIN \
            && "${diagnostic_last_line}" == PERF_INPUT_DIAGNOSTIC_END ]]; then
            printf '%s\n' "${diagnostic_block}"
            exit 0
        fi
        sleep 0.1
    done
    echo "PERF_INPUT_DIAGNOSTIC_ERROR reason=timeout" >&2
    exit 1
fi

sleep 1
podman logs --tail 12 "${PERF_CONTAINER}"
