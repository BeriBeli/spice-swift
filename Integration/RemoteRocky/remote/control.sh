#!/bin/bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

control_wait_attempts="${PERF_CONTROL_WAIT_ATTEMPTS:-100}"
if [[ ! "${control_wait_attempts}" =~ ^[1-9][0-9]{0,3}$ ]] \
    || ((10#${control_wait_attempts} > 1000)); then
    echo "PERF_CONTROL_ERROR reason=invalid_wait_attempts" >&2
    exit 2
fi

send_control_command() {
    local command="$1"
    printf '%s command=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${command}" >> "${run_dir}/control.log"
    podman exec "${PERF_CONTAINER}" \
        bash -c "printf '%s\\n' '${command}' > /dev/tcp/127.0.0.1/${PERF_CONTROL_PORT}"
}

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
        arm_action_class="${2}"
        arm_token="${3}"
        wire_command="arm action_class=${2} token=${3}"
        ;;
    *)
        echo "Usage: $0 {start|reset|stop|status|diagnose-input|arm ACTION_CLASS TOKEN}" >&2
        exit 2
        ;;
esac

require_running
run_dir="$(current_run_dir)"

control_log_offset=
if [[ "${action}" == diagnose-input || "${action}" == arm ]]; then
    if [[ "${action}" == diagnose-input ]]; then
        # A diagnostic invocation owns its complete BEGIN/END response.
        exec 8>"${PERF_STATE}/input-diagnostic.lock"
        flock --exclusive 8
    else
        # Only one host arm may be outstanding while its exact guest result is
        # correlated. Guest input processing remains independent of this lock.
        exec 7>"${PERF_STATE}/input-marker-arm.lock"
        flock --exclusive 7
    fi
    server_log="${run_dir}/server.log"
    if [[ -f "${server_log}" ]]; then
        control_log_offset="$(wc -c < "${server_log}")"
    else
        control_log_offset=0
    fi
fi

if [[ "${action}" == arm ]]; then
    if ! arm_invocation="$(od -An -N16 -tx1 /dev/urandom | tr -d '[:space:]')" \
        || [[ ! "${arm_invocation}" =~ ^[0-9a-f]{32}$ ]]; then
        echo "PERF_ARM_ERROR action_class=${arm_action_class} token=${arm_token} reason=sync_invocation_unavailable" >&2
        exit 1
    fi
    sync_command="sync invocation=${arm_invocation}"
    if ! send_control_command "${sync_command}"; then
        echo "PERF_ARM_ERROR action_class=${arm_action_class} token=${arm_token} reason=sync_send_failed" >&2
        exit 1
    fi
    sync_observed=false
    for ((attempt = 0; attempt < control_wait_attempts; attempt += 1)); do
        if tail -c "+$((control_log_offset + 1))" "${server_log}" 2>/dev/null |
            awk -v expected="PERF_CONTROL_SYNC invocation=${arm_invocation}" '
                {
                    line = $0
                    sub(/\r$/, "", line)
                }
                line == expected { found = 1; exit }
                END { exit(found ? 0 : 1) }
            '; then
            sync_observed=true
            break
        fi
        sleep 0.1
    done
    if [[ "${sync_observed}" != true ]]; then
        echo "PERF_ARM_ERROR action_class=${arm_action_class} token=${arm_token} reason=sync_timeout" >&2
        exit 1
    fi
    # Serial order puts every earlier invocation response before this unique
    # barrier. Only bytes after this newly sampled boundary may satisfy arm.
    control_log_offset="$(wc -c < "${server_log}")"
fi

send_control_command "${wire_command}"

if [[ "${action}" == diagnose-input ]]; then
    for ((attempt = 0; attempt < control_wait_attempts; attempt += 1)); do
        diagnostic_block="$(
            tail -c "+$((control_log_offset + 1))" "${server_log}" 2>/dev/null |
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

if [[ "${action}" == arm ]]; then
    for ((attempt = 0; attempt < control_wait_attempts; attempt += 1)); do
        arm_result="$(
            tail -c "+$((control_log_offset + 1))" "${server_log}" 2>/dev/null |
                awk -v action_class="${arm_action_class}" -v token="${arm_token}" '
                    BEGIN {
                        armed = "PERF_ARMED action_class=" action_class " token=" token
                        rejected = "PERF_ARM_REJECTED action_class=" action_class " token=" token " reason="
                    }
                    {
                        line = $0
                        sub(/\r$/, "", line)
                    }
                    line == armed {
                        print line
                        found = 1
                        exit
                    }
                    line == rejected "arm_outstanding" || line == rejected "duplicate_token" {
                        print line
                        found = 1
                        exit
                    }
                    END { exit(found ? 0 : 1) }
                '
        )" || true
        case "${arm_result}" in
            "PERF_ARMED action_class=${arm_action_class} token=${arm_token}")
                printf '%s\n' "${arm_result}"
                exit 0
                ;;
            "PERF_ARM_REJECTED action_class=${arm_action_class} token=${arm_token} reason="*)
                printf '%s\n' "${arm_result}" >&2
                exit 1
                ;;
        esac
        sleep 0.1
    done
    echo "PERF_ARM_ERROR action_class=${arm_action_class} token=${arm_token} reason=timeout" >&2
    exit 1
fi

sleep 1
podman logs --tail 12 "${PERF_CONTAINER}"
