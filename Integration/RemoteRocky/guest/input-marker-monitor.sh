#!/bin/sh

set -eu
set -o pipefail
export LC_ALL=C

match_action_class() {
    case "$1" in
        # XI2 emits a Raw event and a delivered counterpart for the same
        # physical input. Consume only Raw events so the counterpart cannot
        # satisfy an arm installed immediately after the first event.
        *'(RawKeyPress)'*) echo key ;;
        *'(RawButtonPress)'*) echo click ;;
        *'(RawMotion)'*) echo motion ;;
        *) return 1 ;;
    esac
}

if test "${1:-}" = --self-test-events; then
    while IFS= read -r line; do
        if action_class="$(match_action_class "${line}")"; then
            printf 'PERF_INPUT_MATCH action_class=%s\n' "${action_class}"
        fi
    done
    exit 0
fi

agent_command="${PERF_MARKER_AGENT_COMMAND:-/usr/local/bin/input-marker-agent.sh}"
monitor_state_root="${PERF_MARKER_MONITOR_STATE_DIR:-/run/swiftspice-input-marker-monitor}"
queue_fifo="${monitor_state_root}/dispatch"
motion_active="${monitor_state_root}/motion-active"
event_fifo="${monitor_state_root}/events"
dispatcher_pid=
event_source_pid=
diagnostics=false
monitor_pid=$$
read_index=0

if test "${1:-}" = --self-test-motion-burst; then
    diagnostics=true
fi

valid_invocation() {
    test "${#1}" -eq 32 && ! printf '%s' "$1" | grep -q '[^0-9a-f]'
}

if test "${1:-}" = checkpoint; then
    test "$#" -eq 2 || exit 2
    invocation="$2"
    valid_invocation "${invocation}" || exit 2
    checkpoint_ack="${monitor_state_root}/checkpoint-${invocation}"
    rm -f "${checkpoint_ack}"
    checkpoint_attempts="${PERF_MARKER_MONITOR_CHECKPOINT_ATTEMPTS:-500}"
    case "${checkpoint_attempts}" in
        ''|*[!0-9]*) exit 2 ;;
    esac
    test "${checkpoint_attempts}" -gt 0 \
        && test "${checkpoint_attempts}" -le 5000 || exit 2
    attempt=0
    while ! test -p "${event_fifo}"; do
        test "${attempt}" -lt "${checkpoint_attempts}" || exit 1
        attempt=$((attempt + 1))
        sleep 0.01
    done
    exec 8<> "${event_fifo}"
    printf '__checkpoint__ invocation=%s\n' "${invocation}" >&8
    exec 8>&-
    while test "${attempt}" -lt "${checkpoint_attempts}"; do
        if test -f "${checkpoint_ack}"; then
            rm -f "${checkpoint_ack}"
            exit 0
        fi
        attempt=$((attempt + 1))
        sleep 0.01
    done
    exit 1
fi

mkdir -p "${monitor_state_root}"
rm -f "${queue_fifo}" "${event_fifo}"
rmdir "${motion_active}" 2>/dev/null || true
mkfifo "${queue_fifo}"
exec 3<> "${queue_fifo}"

cleanup() {
    trap - EXIT HUP INT TERM
    if test -n "${event_source_pid}"; then
        kill "${event_source_pid}" 2>/dev/null || true
        wait "${event_source_pid}" 2>/dev/null || true
    fi
    if test -n "${dispatcher_pid}"; then
        kill "${dispatcher_pid}" 2>/dev/null || true
        wait "${dispatcher_pid}" 2>/dev/null || true
    fi
    exec 3>&-
    rmdir "${motion_active}" 2>/dev/null || true
    rm -f "${queue_fifo}" "${event_fifo}"
}

terminate_after_signal() {
    cleanup
    exit 1
}

trap cleanup EXIT
trap terminate_after_signal HUP INT TERM

(
    while IFS= read -r action_class <&3; do
        test "${action_class}" != __stop__ || exit 0
        case "${action_class}" in
            __checkpoint__\ invocation=*)
                invocation="${action_class#__checkpoint__ invocation=}"
                if valid_invocation "${invocation}"; then
                    rmdir "${motion_active}" 2>/dev/null || true
                    : > "${monitor_state_root}/checkpoint-${invocation}"
                    if test "${diagnostics}" = true; then
                        echo "PERF_INPUT_CHECKPOINT invocation=${invocation}"
                    fi
                    continue
                fi
                exit 2
                ;;
        esac
        result=0
        "${agent_command}" input "${action_class}" || result=$?
        if test "${result}" -ne 0; then
            echo "PERF_ERROR input_marker_dispatch=failed status=${result}" >&2
            kill -TERM "${monitor_pid}" 2>/dev/null || true
            exit "${result}"
        fi
    done
) &
dispatcher_pid=$!

dispatch_action() {
    action_class="$1"
    if test "${action_class}" = motion; then
        # This directory is the burst ownership token. It is created before
        # publication and consumed only by the next arm's explicit checkpoint.
        # The checkpoint follows every earlier event record through this reader
        # and then every earlier agent call through the worker, so reader
        # scheduling cannot move an old RawMotion into the next arm epoch.
        if ! mkdir "${motion_active}" 2>/dev/null; then
            if test "${diagnostics}" = true; then
                echo "PERF_INPUT_COALESCED action_class=motion"
            fi
            return
        fi
    fi
    printf '%s\n' "${action_class}" >&3
}

process_events() {
    while IFS= read -r line; do
        read_index=$((read_index + 1))
        if test -n "${PERF_MARKER_MONITOR_BEFORE_READ_FILE:-}"; then
            gate="${PERF_MARKER_MONITOR_BEFORE_READ_FILE}"
            : > "${gate}.entered.${read_index}"
            while ! test -e "${gate}.release.${read_index}"; do
                sleep 0.01
            done
        fi
        case "${line}" in
            __checkpoint__\ invocation=*)
                invocation="${line#__checkpoint__ invocation=}"
                valid_invocation "${invocation}" || exit 2
                printf '__checkpoint__ invocation=%s\n' "${invocation}" >&3
                continue
                ;;
        esac
        if action_class="$(match_action_class "${line}")"; then
            dispatch_action "${action_class}"
        fi
    done
}

if test "${1:-}" = --self-test-motion-burst; then
    test "$#" -eq 1 || exit 2
    process_events
    printf '%s\n' __stop__ >&3
    wait "${dispatcher_pid}"
    dispatcher_pid=
    exit 0
fi

test "$#" -eq 0 || exit 2
# xinput uses block buffering when stdout is a pipe. Force each event record to
# reach the reader immediately. The reader only performs fixed-size FIFO writes;
# the serialized agent worker cannot stop XI2 draining. Key and click records
# remain FIFO, while at most one motion from an active burst is queued/running.
mkfifo "${event_fifo}"
stdbuf -oL -eL xinput test-xi2 --root > "${event_fifo}" &
event_source_pid=$!
process_events < "${event_fifo}"
wait "${event_source_pid}"
event_source_pid=
printf '%s\n' __stop__ >&3
wait "${dispatcher_pid}"
dispatcher_pid=
