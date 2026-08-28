#!/bin/sh

set -eu

state_dir="${PERF_MARKER_STATE_DIR:-/run/swiftspice-input-marker}"
request_fifo="${PERF_MARKER_REQUEST_FIFO:-/run/perf-marker-request}"
ack_fifo="${PERF_MARKER_ACK_FIFO:-/run/perf-marker-ack}"
MARKER_FOREGROUND=000000
MARKER_BACKGROUND=ffffff
mkdir -p "${state_dir}"

fail() {
    echo "PERF_ERROR input_marker=$1" >&2
    exit 1
}

reject_arm() {
    echo "PERF_ARM_REJECTED action_class=$1 token=$2 reason=$3" >&2
    exit 1
}

valid_action_class() {
    case "$1" in
        click|key|motion) return 0 ;;
        *) return 1 ;;
    esac
}

valid_token() {
    test "${#1}" -eq 16 && ! printf '%s' "$1" | grep -q '[^0-9a-f]'
}

valid_uint64_text() {
    test -n "$1" && ! printf '%s' "$1" | grep -q '[^0-9]'
}

monotonic_nanoseconds() {
    awk '{ printf "%.0f\n", $1 * 1000000000 }' /proc/uptime
}

render_marker() {
    token="$1"
    marker_revision="$2"
    checksum="$(printf '%s' "${token}" | sha256sum | awk '{ print substr($1, 1, 8) }')"
    payload="SWIFTSPICE_MARKER token=${token} marker_revision=${marker_revision} checksum=${checksum}"
    if test "${PERF_MARKER_TEST_MODE:-0}" = 1; then
        echo "PERF_MARKER_RENDER ${payload} foreground=${MARKER_FOREGROUND} background=${MARKER_BACKGROUND}"
        return
    fi
    printf '%s\n' "${payload}" > "${request_fifo}"
    acknowledged_revision="$(cat "${ack_fifo}")"
    test "${acknowledged_revision}" = "${marker_revision}" || fail marker_ack_mismatch
}

if test "${1:-}" = --self-test-jsonl; then
    while IFS= read -r line; do
        set -f
        # The accepted protocol contains only fixed keys and values without
        # whitespace; direct invocations below retain the production validator.
        set -- ${line}
        case "${1:-}" in
            arm)
                if test "$#" -ne 3 \
                    || test "${2#action_class=}" = "$2" \
                    || test "${3#token=}" = "$3"; then
                    echo "PERF_ERROR input_marker=invalid_arm"
                    continue
                fi
                action_class="${2#action_class=}"
                token="${3#token=}"
                if output="$(PERF_MARKER_STATE_DIR="${state_dir}" PERF_MARKER_TEST_MODE=1 \
                    /bin/sh "$0" arm "${action_class}" "${token}" 2>&1)"; then
                    printf '%s\n' "${output}"
                else
                    case "${output}" in
                        PERF_ARM_REJECTED\ action_class=*) printf '%s\n' "${output}" ;;
                        PERF_ERROR\ input_marker=*) printf '%s\n' "${output}" ;;
                        *) printf '%s\n' "${output}" >&2; exit 1 ;;
                    esac
                fi
                ;;
            input)
                if test "$#" -ne 3 \
                    || test "${2#action_class=}" = "$2" \
                    || test "${3#guest_ns=}" = "$3"; then
                    echo "PERF_ERROR input_marker=invalid_input"
                    continue
                fi
                action_class="${2#action_class=}"
                guest_received_ns="${3#guest_ns=}"
                marker_drawn_ns=$((guest_received_ns + 1))
                if output="$(PERF_MARKER_STATE_DIR="${state_dir}" PERF_MARKER_TEST_MODE=1 \
                    /bin/sh "$0" input "${action_class}" "${guest_received_ns}" \
                    "${marker_drawn_ns}" 2>&1)"; then
                    if test -n "${output}"; then
                        printf '%s\n' "${output}"
                    fi
                else
                    case "${output}" in
                        PERF_ERROR\ input_marker=*) printf '%s\n' "${output}" ;;
                        *) printf '%s\n' "${output}" >&2; exit 1 ;;
                    esac
                fi
                ;;
            *)
                echo "PERF_ERROR input_marker=invalid_command"
                ;;
        esac
    done
    exit 0
fi

lock_dir="${state_dir}/lock"
if ! mkdir "${lock_dir}" 2>/dev/null; then
    fail state_busy
fi
release_lock() {
    rmdir "${lock_dir}" 2>/dev/null || true
}
terminate_after_signal() {
    trap - EXIT HUP INT TERM
    release_lock
    exit 1
}
trap release_lock EXIT
trap terminate_after_signal HUP INT TERM

# Deterministic signal/lifetime seam. Production never sets this variable.
if test -n "${PERF_MARKER_HOLD_AFTER_LOCK_FILE:-}"; then
    : > "${PERF_MARKER_HOLD_AFTER_LOCK_FILE}.entered"
    while ! test -e "${PERF_MARKER_HOLD_AFTER_LOCK_FILE}.release"; do
        sleep 0.01
    done
fi

command="${1:-}"
action_class="${2:-}"
valid_action_class "${action_class}" || fail invalid_action_class

case "${command}" in
    arm)
        test "$#" -eq 3 || fail invalid_arm
        token="$3"
        valid_token "${token}" || fail invalid_token
        if test -f "${state_dir}/armed"; then
            reject_arm "${action_class}" "${token}" arm_outstanding
        fi
        if test -f "${state_dir}/used-tokens" \
            && grep -Fqx "${token}" "${state_dir}/used-tokens"; then
            reject_arm "${action_class}" "${token}" duplicate_token
        fi
        arm_tmp="${state_dir}/armed.$$"
        printf '%s %s\n' "${action_class}" "${token}" > "${arm_tmp}"
        mv "${arm_tmp}" "${state_dir}/armed"
        printf '%s\n' "${token}" >> "${state_dir}/used-tokens"
        echo "PERF_ARMED action_class=${action_class} token=${token}"
        ;;
    input)
        test "$#" -ge 2 && test "$#" -le 4 || fail invalid_input
        if ! test -f "${state_dir}/armed"; then
            exit 0
        fi
        read -r armed_class token < "${state_dir}/armed"
        if test "${action_class}" != "${armed_class}"; then
            exit 0
        fi
        guest_received_ns="${3:-$(monotonic_nanoseconds)}"
        valid_uint64_text "${guest_received_ns}" || fail invalid_guest_timestamp
        rm -f "${state_dir}/armed"

        marker_revision=1
        if test -f "${state_dir}/marker-revision"; then
            marker_revision=$(( $(cat "${state_dir}/marker-revision") + 1 ))
        fi
        printf '%s\n' "${marker_revision}" > "${state_dir}/marker-revision"
        echo "PERF_TRACE event=guest_received action_class=${action_class} token=${token} guest_ns=${guest_received_ns} marker_revision=${marker_revision}"
        render_marker "${token}" "${marker_revision}"
        marker_drawn_ns="${4:-$(monotonic_nanoseconds)}"
        valid_uint64_text "${marker_drawn_ns}" || fail invalid_marker_timestamp
        test "${marker_drawn_ns}" -ge "${guest_received_ns}" || fail marker_time_regressed
        echo "PERF_TRACE event=marker_drawn action_class=${action_class} token=${token} guest_ns=${marker_drawn_ns} marker_revision=${marker_revision}"
        ;;
    *)
        fail invalid_command
        ;;
esac
