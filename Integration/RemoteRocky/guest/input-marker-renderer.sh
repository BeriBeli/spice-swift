#!/bin/sh

set -eu

request_fifo="${PERF_MARKER_REQUEST_FIFO:-/run/perf-marker-request}"
ack_fifo="${PERF_MARKER_ACK_FIFO:-/run/perf-marker-ack}"
test_mode=false
workload_pid=
saved_terminal_state=
request_fd_open=false
barrier_input_fd_open=false
barrier_timeout_ns=500000000
host_barrier_transport_runs=0

restore_terminal_state() {
    if test -n "${saved_terminal_state}"; then
        stty "${saved_terminal_state}" < /dev/tty 2>/dev/null || true
        saved_terminal_state=
    fi
}

cleanup() {
    trap - EXIT HUP INT TERM
    restore_terminal_state
    if test "${request_fd_open}" = true; then
        exec 5>&-
        request_fd_open=false
    fi
    if test "${barrier_input_fd_open}" = true; then
        exec 6<&-
        barrier_input_fd_open=false
    fi
    if test -n "${workload_pid}"; then
        kill "${workload_pid}" 2>/dev/null || true
        # SIGTERM remains pending while a process is job-control stopped.
        kill -CONT "${workload_pid}" 2>/dev/null || true
        wait "${workload_pid}" 2>/dev/null || true
    fi
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
        python3 -c 'import time; print(time.monotonic_ns())'
    else
        return 1
    fi
}

read_barrier_byte() {
    remaining_ns="$1"
    barrier_byte=
    timeout_seconds="$(awk -v nanoseconds="${remaining_ns}" \
        'BEGIN { printf "%.6f", nanoseconds / 1000000000 }')"
    IFS= read -r -n 1 -t "${timeout_seconds}" barrier_byte <&6
}

await_host_terminal_status() {
    remaining_ns="$1"
    host_barrier_transport_runs=1
    barrier_hex=
    if barrier_hex="$(python3 -c '
from collections import deque
import os
import select
import sys
import time

deadline = time.monotonic_ns() + int(sys.argv[1])
window = deque(maxlen=4096)
state = 0
while True:
    remaining = deadline - time.monotonic_ns()
    if remaining <= 0 or not select.select([6], [], [], remaining / 1_000_000_000)[0]:
        raise SystemExit(1)
    chunk = os.read(6, 4096)
    if not chunk:
        raise SystemExit(2)
    for value in chunk:
        window.append(value)
        if state == 0:
            state = 1 if value == 0x1B else 0
        elif state == 1:
            state = 2 if value == 0x5B else (1 if value == 0x1B else 0)
        elif state == 2:
            state = 3 if value == 0x30 else (1 if value == 0x1B else 0)
        else:
            if value == 0x6E:
                sys.stdout.write(bytes(window).hex())
                raise SystemExit(0)
            state = 1 if value == 0x1B else 0
' "${remaining_ns}" 6<&6)"; then
        :
    else
        return 1
    fi

    # Python is only the host-test transport: one bounded process may perform
    # multiple select/read calls and returns a capped hex cache. Reconfirm the
    # exact response with the same transitions used by the guest shell path.
    barrier_state=ground
    while test -n "${barrier_hex}"; do
        byte_hex="${barrier_hex%"${barrier_hex#??}"}"
        barrier_hex="${barrier_hex#??}"
        case "${barrier_state}:${byte_hex}" in
            ground:1b) barrier_state=escape ;;
            escape:5b) barrier_state=bracket ;;
            bracket:30) barrier_state=zero ;;
            zero:6e) return 0 ;;
            *:1b) barrier_state=escape ;;
            *) barrier_state=ground ;;
        esac
    done
    return 1
}

await_terminal_status() {
    barrier_started_ns="$(monotonic_nanoseconds)" || return 1
    valid_uint64_text "${barrier_started_ns}" || return 1
    barrier_deadline_ns=$((barrier_started_ns + barrier_timeout_ns))
    barrier_state=ground
    escape="$(printf '\033')"
    if ! test -x /usr/local/bin/monotonic-nanoseconds; then
        barrier_now_ns="$(monotonic_nanoseconds)" || return 1
        valid_uint64_text "${barrier_now_ns}" || return 1
        remaining_ns=$((barrier_deadline_ns - barrier_now_ns))
        test "${remaining_ns}" -gt 0 || return 1
        await_host_terminal_status "${remaining_ns}"
        return
    fi
    while true; do
        barrier_now_ns="$(monotonic_nanoseconds)" || return 1
        valid_uint64_text "${barrier_now_ns}" || return 1
        remaining_ns=$((barrier_deadline_ns - barrier_now_ns))
        test "${remaining_ns}" -gt 0 || return 1
        read_barrier_byte "${remaining_ns}" || return 1
        case "${barrier_state}:${barrier_byte}" in
            "ground:${escape}") barrier_state=escape ;;
            "escape:[") barrier_state=bracket ;;
            "bracket:0") barrier_state=zero ;;
            "zero:n") return 0 ;;
            *:"${escape}") barrier_state=escape ;;
            *) barrier_state=ground ;;
        esac
    done
}

terminate_after_signal() {
    cleanup
    exit 1
}

trap cleanup EXIT
trap terminate_after_signal HUP INT TERM

draw_marker() {
    workload="$1"
    token="$2"
    revision="$3"
    checksum="$4"
    if test "${test_mode}" = true; then
        echo "PERF_MARKER_WORKLOAD action=draw workload=${workload} token=${token} marker_revision=${revision}"
        return
    fi

    # Rows 1-4 are reserved by both fullscreen workloads. Emit the complete
    # ROI in one terminal write while the animation producer is stopped.
    printf '\033[1;1H\033[30;107m\033[2KCAUSAL INPUT MARKER\n\033[2Ktoken=%s\n\033[2Kmarker_revision=%s checksum=%s\n\033[2K\033[0m' \
        "${token}" "${revision}" "${checksum}" > /dev/tty
}

terminal_visibility_barrier() {
    workload="$1"
    token="$2"
    revision="$3"
    if test "${test_mode}" = true; then
        echo "PERF_MARKER_WORKLOAD action=barrier workload=${workload} token=${token} marker_revision=${revision}"
        return
    fi

    # Xterm answers CSI 5 n only after consuming all preceding terminal input.
    # One absolute monotonic deadline bounds the complete parser to half a
    # second. The state machine ignores unrelated bytes (including printable
    # `n`) and accepts only the exact ESC [ 0 n response. Timeout or EOF fails
    # this event without ACK.
    saved_terminal_state="$(stty -g < /dev/tty)"
    stty -echo -icanon min 1 time 0 < /dev/tty
    exec 6< /dev/tty
    barrier_input_fd_open=true
    printf '\033[5n' > /dev/tty
    result=0
    await_terminal_status || result=$?
    exec 6<&-
    barrier_input_fd_open=false
    restore_terminal_state
    return "${result}"
}

acknowledge_marker() {
    workload="$1"
    token="$2"
    revision="$3"
    if test "${test_mode}" = true; then
        echo "PERF_MARKER_WORKLOAD action=ack workload=${workload} token=${token} marker_revision=${revision}"
        return
    fi
    printf '%s\n' "${revision}" >&4
}

process_marker() {
    workload="$1"
    marker="$2"
    token_field="$3"
    revision_field="$4"
    checksum_field="$5"
    token="${token_field#token=}"
    revision="${revision_field#marker_revision=}"
    checksum="${checksum_field#checksum=}"
    test "${marker}" = SWIFTSPICE_MARKER || return 1
    test "${token}" != "${token_field}" || return 1
    test "${revision}" != "${revision_field}" || return 1
    test "${checksum}" != "${checksum_field}" || return 1

    if test -n "${workload_pid}"; then
        kill -STOP "${workload_pid}"
    fi
    result=0
    draw_marker "${workload}" "${token}" "${revision}" "${checksum}" \
        && terminal_visibility_barrier "${workload}" "${token}" "${revision}" \
        && acknowledge_marker "${workload}" "${token}" "${revision}" \
        || result=$?
    if test -n "${workload_pid}"; then
        kill -CONT "${workload_pid}" 2>/dev/null || true
    fi
    return "${result}"
}

case "${1:-}" in
    --self-test-barrier)
        test "$#" -eq 1 || exit 2
        if test -n "${PERF_MARKER_SELF_TEST_BARRIER_TIMEOUT_NS:-}"; then
            barrier_timeout_ns="${PERF_MARKER_SELF_TEST_BARRIER_TIMEOUT_NS}"
            valid_uint64_text "${barrier_timeout_ns}" || exit 2
            test "${barrier_timeout_ns}" -gt 0 \
                && test "${barrier_timeout_ns}" -le 500000000 || exit 2
        fi
        exec 6<&0
        barrier_input_fd_open=true
        if await_terminal_status; then
            if test "${PERF_MARKER_SELF_TEST_BARRIER_DIAGNOSTICS:-0}" = 1; then
                echo "PERF_MARKER_BARRIER_TRANSPORT runs=${host_barrier_transport_runs}"
            fi
            echo "PERF_MARKER_BARRIER accepted"
            exit 0
        fi
        if test "${PERF_MARKER_SELF_TEST_BARRIER_DIAGNOSTICS:-0}" = 1; then
            echo "PERF_MARKER_BARRIER_TRANSPORT runs=${host_barrier_transport_runs}"
        fi
        echo "PERF_MARKER_BARRIER rejected" >&2
        exit 1
        ;;
    --self-test-workload)
        test "$#" -eq 2 || exit 2
        workload="$2"
        case "${workload}" in
            static|animation) ;;
            *) exit 2 ;;
        esac
        test_mode=true
        if ! read -r marker token_field revision_field checksum_field; then
            exit 2
        fi
        process_marker "${workload}" "${marker}" "${token_field}" \
            "${revision_field}" "${checksum_field}"
        exit
        ;;
    --self-test-fifo)
        test "$#" -eq 1 || exit 2
        self_test_request_count="${PERF_MARKER_SELF_TEST_REQUEST_COUNT:-}"
        valid_uint64_text "${self_test_request_count}" || exit 2
        test "${self_test_request_count}" -gt 0 \
            && test "${self_test_request_count}" -le 100 || exit 2
        workload=static
        test_mode=true
        ;;
    workload)
        test "$#" -eq 2 || exit 2
        workload="$2"
        ;;
    *)
        exit 2
        ;;
esac

case "${workload}" in
    static)
        if test "${test_mode}" = true; then
            echo "PERF_MARKER_WORKLOAD action=ready"
        else
            printf '\033[2J\033[6;1H'
            printf 'SwiftSpice remote performance fixture\n\n'
            printf 'Resolution: 1280x720\n'
            printf 'State: static baseline\n'
            printf 'Animation: stopped\n\n'
            printf 'Use the remote control script to start or reset the load.\n'
        fi
        ;;
    animation)
        /usr/local/bin/animation-generator.sh &
        workload_pid=$!
        ;;
    *)
        exit 2
        ;;
esac

# Keep a nonblocking writer endpoint for late completion. If an agent times out
# while this renderer is leaving the visibility barrier, its closed reader must
# not strand the active fullscreen workload in a FIFO open.
exec 4<> "${ack_fifo}"
exec 5<> "${request_fifo}"
request_fd_open=true

processed_requests=0
while true; do
    if read -r marker token_field revision_field checksum_field <&5; then
        if ! process_marker "${workload}" "${marker}" "${token_field}" \
            "${revision_field}" "${checksum_field}"; then
            echo "PERF_ERROR input_marker_renderer=visibility_barrier" >&2
        fi
        if test "${test_mode}" = true; then
            processed_requests=$((processed_requests + 1))
            if test -n "${PERF_MARKER_SELF_TEST_AFTER_PROCESS_FILE:-}"; then
                gate="${PERF_MARKER_SELF_TEST_AFTER_PROCESS_FILE}"
                : > "${gate}.entered.${processed_requests}"
                while ! test -e "${gate}.release.${processed_requests}"; do
                    sleep 0.01
                done
            fi
            if test "${processed_requests}" -eq "${self_test_request_count}"; then
                exit 0
            fi
        fi
    fi
done
