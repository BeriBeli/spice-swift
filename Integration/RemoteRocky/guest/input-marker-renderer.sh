#!/bin/sh

set -eu

request_fifo="${PERF_MARKER_REQUEST_FIFO:-/run/perf-marker-request}"
ack_fifo="${PERF_MARKER_ACK_FIFO:-/run/perf-marker-ack}"
test_mode=false
workload_pid=
saved_terminal_state=

restore_terminal_state() {
    if test -n "${saved_terminal_state}"; then
        stty "${saved_terminal_state}" < /dev/tty 2>/dev/null || true
        saved_terminal_state=
    fi
}

cleanup() {
    trap - EXIT HUP INT TERM
    restore_terminal_state
    if test -n "${workload_pid}"; then
        kill "${workload_pid}" 2>/dev/null || true
        # SIGTERM remains pending while a process is job-control stopped.
        kill -CONT "${workload_pid}" 2>/dev/null || true
        wait "${workload_pid}" 2>/dev/null || true
    fi
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
    # Temporarily make the pty noncanonical so the response needs no newline;
    # unrelated key bytes are ignored until the exact terminal response ends.
    saved_terminal_state="$(stty -g < /dev/tty)"
    stty -echo -icanon min 1 time 0 < /dev/tty
    printf '\033[5n' > /dev/tty
    response=
    count=0
    escape="$(printf '\033')"
    while test "${count}" -lt 64; do
        character=
        if ! IFS= read -r -n 1 -t 2 character < /dev/tty; then
            restore_terminal_state
            return 1
        fi
        response="${response}${character}"
        case "${response}" in
            *"${escape}[0n")
                restore_terminal_state
                return 0
                ;;
        esac
        count=$((count + 1))
    done
    restore_terminal_state
    return 1
}

acknowledge_marker() {
    workload="$1"
    token="$2"
    revision="$3"
    if test "${test_mode}" = true; then
        echo "PERF_MARKER_WORKLOAD action=ack workload=${workload} token=${token} marker_revision=${revision}"
        return
    fi
    printf '%s\n' "${revision}" > "${ack_fifo}"
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
        printf '\033[2J\033[6;1H'
        printf 'SwiftSpice remote performance fixture\n\n'
        printf 'Resolution: 1280x720\n'
        printf 'State: static baseline\n'
        printf 'Animation: stopped\n\n'
        printf 'Use the remote control script to start or reset the load.\n'
        ;;
    animation)
        /usr/local/bin/animation-generator.sh &
        workload_pid=$!
        ;;
    *)
        exit 2
        ;;
esac

while true; do
    if read -r marker token_field revision_field checksum_field < "${request_fifo}"; then
        if ! process_marker "${workload}" "${marker}" "${token_field}" \
            "${revision_field}" "${checksum_field}"; then
            echo "PERF_ERROR input_marker_renderer=visibility_barrier" >&2
        fi
    fi
done
