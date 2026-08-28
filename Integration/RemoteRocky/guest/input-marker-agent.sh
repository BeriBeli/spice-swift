#!/bin/sh

set -eu

state_dir="${PERF_MARKER_STATE_DIR:-/run/swiftspice-input-marker}"
request_fifo="${PERF_MARKER_REQUEST_FIFO:-/run/perf-marker-request}"
ack_fifo="${PERF_MARKER_ACK_FIFO:-/run/perf-marker-ack}"
ack_timeout_seconds="${PERF_MARKER_ACK_TIMEOUT_SECONDS:-2}"
MARKER_FOREGROUND=000000
MARKER_BACKGROUND=ffffff
ack_fd_open=false
request_fd_open=false
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
    if test -n "${PERF_MARKER_CLOCK_COMMAND:-}"; then
        "${PERF_MARKER_CLOCK_COMMAND}"
    elif test -x /usr/local/bin/monotonic-nanoseconds; then
        /usr/local/bin/monotonic-nanoseconds
    elif command -v python3 >/dev/null 2>&1; then
        # Host-run shell tests do not boot the Alpine initramfs. Production
        # always installs the static clock_gettime helper above.
        python3 -c 'import time; print(time.monotonic_ns())'
    else
        return 1
    fi
}

event_clock_nanoseconds() {
    value="$(monotonic_nanoseconds)" || return 1
    valid_uint64_text "${value}" || return 1
    printf '%s\n' "${value}"
}

clock_samples() {
    count="$1"
    if test -n "${PERF_MARKER_CLOCK_COMMAND:-}"; then
        "${PERF_MARKER_CLOCK_COMMAND}" "${count}"
    elif test -x /usr/local/bin/monotonic-nanoseconds; then
        /usr/local/bin/monotonic-nanoseconds "${count}"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c '
import sys
import time

for _ in range(int(sys.argv[1])):
    print(time.monotonic_ns())
' "${count}"
    else
        return 1
    fi
}

read_ack_record() {
    timeout_ns="$1"
    if test -x /usr/local/bin/monotonic-nanoseconds; then
        # The Alpine initramfs pairs the static clock helper with BusyBox ash,
        # whose `read -t` accepts fractional seconds.
        timeout_seconds="$(awk -v nanoseconds="${timeout_ns}" \
            'BEGIN { printf "%.6f", nanoseconds / 1000000000 }')"
        IFS= read -r -t "${timeout_seconds}" acknowledged_revision <&3
        return
    fi

    # macOS's system Bash (used by the host-run fixture tests) accepts only an
    # integer `read -t`. Keep the same nanosecond deadline with select(2)
    # instead of rounding it and changing the production timing contract.
    acknowledged_revision="$(python3 -c '
import os
import select
import sys

timeout = int(sys.argv[1]) / 1_000_000_000
if not select.select([3], [], [], timeout)[0]:
    raise SystemExit(1)
record = bytearray()
while True:
    byte = os.read(3, 1)
    if not byte:
        raise SystemExit(2)
    if byte == b"\n":
        break
    record.extend(byte)
sys.stdout.buffer.write(record)
' "${timeout_ns}" 3<&3)"
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

    valid_uint64_text "${ack_timeout_seconds}" || fail invalid_ack_timeout
    test "${ack_timeout_seconds}" -gt 0 || fail invalid_ack_timeout
    test "${ack_timeout_seconds}" -le 60 || fail invalid_ack_timeout
    ack_started_ns="$(event_clock_nanoseconds)" || fail marker_clock_unavailable
    ack_deadline_ns=$((ack_started_ns + ack_timeout_seconds * 1000000000))
    # Opening either FIFO in only one direction can wait forever for its peer.
    # O_RDWR establishes both ends without waiting. There is one outstanding
    # event and one fixed record far below PIPE_BUF, so publication cannot fill
    # this freshly owned request pipe; closing FD 5 also discards an unconsumed
    # request before any future renderer can open it.
    exec 3<> "${ack_fifo}"
    ack_fd_open=true
    exec 5<> "${request_fifo}"
    request_fd_open=true

    # The same absolute deadline is already running when publication becomes
    # visible.
    # FD 5 cannot block on open, and this single bounded write cannot exhaust
    # the empty FIFO capacity under the one-outstanding-event invariant.
    if ! printf '%s\n' "${payload}" >&5; then
        exec 5>&-
        request_fd_open=false
        fail marker_request_failed
    fi
    exec 5>&-
    request_fd_open=false

    ack_status=timeout
    saw_mismatch=false
    while true; do
        ack_now_ns="$(event_clock_nanoseconds)" || fail marker_clock_unavailable
        remaining_ns=$((ack_deadline_ns - ack_now_ns))
        test "${remaining_ns}" -gt 0 || break
        acknowledged_revision=
        if ! read_ack_record "${remaining_ns}"; then
            break
        fi
        if test "${acknowledged_revision}" = "${marker_revision}"; then
            ack_status=accepted
            break
        fi
        saw_mismatch=true
    done
    exec 3>&-
    ack_fd_open=false
    if test "${ack_status}" != accepted && test "${saw_mismatch}" = true; then
        ack_status=mismatch
    fi
    case "${ack_status}" in
        accepted) return 0 ;;
        mismatch) fail marker_ack_mismatch ;;
        *) fail marker_ack_timeout ;;
    esac
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

if test "${1:-}" = --self-test-clock; then
    test "$#" -eq 2 || fail invalid_clock_sample_count
    valid_uint64_text "$2" || fail invalid_clock_sample_count
    test "$2" -gt 0 && test "$2" -le 100 || fail invalid_clock_sample_count
    samples="$(clock_samples "$2")" || fail marker_clock_unavailable
    if ! printf '%s\n' "${samples}" | awk -v expected="$2" '
        /^[0-9]+$/ {
            print "PERF_MARKER_CLOCK monotonic_ns=" $0
            count += 1
            next
        }
        { invalid = 1 }
        END { exit(invalid || count != expected) }
    '; then
        fail marker_clock_unavailable
    fi
    exit 0
fi

lock_dir="${state_dir}/lock"
if ! mkdir "${lock_dir}" 2>/dev/null; then
    fail state_busy
fi
release_lock() {
    if test "${request_fd_open}" = true; then
        exec 5>&-
        request_fd_open=false
    fi
    if test "${ack_fd_open}" = true; then
        exec 3>&-
        ack_fd_open=false
    fi
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
        if test "$#" -ge 3; then
            guest_received_ns="$3"
        else
            guest_received_ns="$(event_clock_nanoseconds)" || fail marker_clock_unavailable
        fi
        valid_uint64_text "${guest_received_ns}" || fail invalid_guest_timestamp
        rm -f "${state_dir}/armed"

        marker_revision=1
        if test -f "${state_dir}/marker-revision"; then
            marker_revision=$(( $(cat "${state_dir}/marker-revision") + 1 ))
        fi
        printf '%s\n' "${marker_revision}" > "${state_dir}/marker-revision"
        echo "PERF_TRACE event=guest_received action_class=${action_class} token=${token} guest_ns=${guest_received_ns} marker_revision=${marker_revision}"
        render_marker "${token}" "${marker_revision}"
        if test "$#" -eq 4; then
            marker_drawn_ns="$4"
        else
            marker_drawn_ns="$(event_clock_nanoseconds)" || fail marker_clock_unavailable
        fi
        valid_uint64_text "${marker_drawn_ns}" || fail invalid_marker_timestamp
        test "${marker_drawn_ns}" -ge "${guest_received_ns}" || fail marker_time_regressed
        echo "PERF_TRACE event=marker_drawn action_class=${action_class} token=${token} guest_ns=${marker_drawn_ns} marker_revision=${marker_revision}"
        ;;
    *)
        fail invalid_command
        ;;
esac
