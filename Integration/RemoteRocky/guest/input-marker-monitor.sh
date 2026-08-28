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
checkpoint_request="${monitor_state_root}/checkpoint-request"
checkpoint_lock="${monitor_state_root}/checkpoint-active"
monitor_pid_file="${monitor_state_root}/monitor-pid"
dispatcher_pid=
event_source_pid=
event_reader_pid=
source_ready=
rotate_requested=false
diagnostics=false
monitor_pid=$$
read_index=0

if test "${1:-}" = --self-test-motion-burst; then
    diagnostics=true
fi

valid_invocation() {
    test "${#1}" -eq 32 && ! printf '%s' "$1" | grep -q '[^0-9a-f]'
}

monitor_identity_is_current() {
    target_pid="$1"
    test "${target_pid}" != "$$" || return 1
    if test -r "/proc/${target_pid}/cmdline"; then
        tr '\000' '\n' < "/proc/${target_pid}/cmdline" | awk '
            /(^|\/)input-marker-monitor[.]sh$/ { monitor_scripts += 1 }
            $0 == "checkpoint" { checkpoint_child = 1 }
            END { exit(monitor_scripts != 1 || checkpoint_child) }
        '
        return
    fi

    # Host-run macOS tests have no procfs. Their repository path contains no
    # whitespace, so ps argv fields retain the same exact script/argument gate.
    command -v ps >/dev/null 2>&1 || return 1
    target_command="$(ps -ww -p "${target_pid}" -o command= 2>/dev/null)" \
        || return 1
    printf '%s\n' "${target_command}" | awk '
        {
            for (field_index = 1; field_index <= NF; field_index += 1) {
                if ($field_index ~ /(^|\/)input-marker-monitor[.]sh$/) {
                    monitor_scripts += 1
                }
                if ($field_index == "checkpoint") {
                    checkpoint_child = 1
                }
            }
        }
        END { exit(monitor_scripts != 1 || checkpoint_child) }
    '
}

if test "${1:-}" = checkpoint; then
    test "$#" -eq 2 || exit 2
    invocation="$2"
    valid_invocation "${invocation}" || exit 2
    checkpoint_ack="${monitor_state_root}/checkpoint-${invocation}"
    checkpoint_attempts="${PERF_MARKER_MONITOR_CHECKPOINT_ATTEMPTS:-500}"
    case "${checkpoint_attempts}" in
        ''|*[!0-9]*) exit 2 ;;
    esac
    test "${checkpoint_attempts}" -gt 0 \
        && test "${checkpoint_attempts}" -le 5000 || exit 2
    attempt=0
    # An immediate checkpoint may be scheduled before the monitor creates its
    # state directory. Spend the one shared budget waiting for a published,
    # signal-safe target before trying to acquire the per-monitor checkpoint
    # lock; a missing parent directory is not a concurrent-checkpoint verdict.
    while ! test -p "${event_fifo}" || ! test -s "${monitor_pid_file}"; do
        test "${attempt}" -lt "${checkpoint_attempts}" || exit 1
        attempt=$((attempt + 1))
        sleep 0.01
    done
    if ! mkdir "${checkpoint_lock}" 2>/dev/null; then
        exit 1
    fi
    cleanup_checkpoint() {
        rm -f "${checkpoint_request}.tmp.$$"
        rmdir "${checkpoint_lock}" 2>/dev/null || true
    }
    terminate_checkpoint() {
        trap - EXIT HUP INT TERM
        cleanup_checkpoint
        exit 1
    }
    trap cleanup_checkpoint EXIT
    trap terminate_checkpoint HUP INT TERM
    # The monitor could retire between readiness observation and lock
    # acquisition. Revalidate under checkpoint ownership and fail closed rather
    # than signalling a stale or replacement process.
    test -p "${event_fifo}" && test -s "${monitor_pid_file}" || exit 1
    read -r active_monitor_pid < "${monitor_pid_file}"
    case "${active_monitor_pid}" in
        ''|*[!0-9]*) exit 1 ;;
    esac
    kill -0 "${active_monitor_pid}" 2>/dev/null || exit 1
    monitor_identity_is_current "${active_monitor_pid}" || exit 1
    rm -f "${checkpoint_ack}"
    printf '%s\n' "${invocation}" > "${checkpoint_request}.tmp.$$"
    mv "${checkpoint_request}.tmp.$$" "${checkpoint_request}"
    # The monitor owns the source PID. USR1 asks that same process to close
    # the current XI2 client; the monitor then drains its stdout through EOF
    # before publishing the checkpoint to the serialized worker.
    kill -USR1 "${active_monitor_pid}" 2>/dev/null || exit 1
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
rm -f "${queue_fifo}" "${event_fifo}" "${checkpoint_request}" \
    "${monitor_pid_file}"
rmdir "${checkpoint_lock}" 2>/dev/null || true
rmdir "${motion_active}" 2>/dev/null || true
mkfifo "${queue_fifo}"
exec 3<> "${queue_fifo}"

cleanup() {
    trap - EXIT HUP INT TERM
    if test -n "${event_source_pid}"; then
        kill "${event_source_pid}" 2>/dev/null || true
        wait "${event_source_pid}" 2>/dev/null || true
    fi
    if test -n "${event_reader_pid}"; then
        kill "${event_reader_pid}" 2>/dev/null || true
        wait "${event_reader_pid}" 2>/dev/null || true
    fi
    if test -n "${dispatcher_pid}"; then
        kill "${dispatcher_pid}" 2>/dev/null || true
        wait "${dispatcher_pid}" 2>/dev/null || true
    fi
    exec 3>&-
    rmdir "${motion_active}" 2>/dev/null || true
    rm -f "${queue_fifo}" "${event_fifo}" "${checkpoint_request}" \
        "${monitor_pid_file}"
    if test -n "${source_ready}"; then
        rm -f "${source_ready}"
    fi
    rmdir "${checkpoint_lock}" 2>/dev/null || true
}

rotate_event_source() {
    rotate_requested=true
    if test -n "${event_source_pid}"; then
        kill -TERM "${event_source_pid}" 2>/dev/null || true
    fi
}

terminate_after_signal() {
    cleanup
    exit 1
}

trap cleanup EXIT
trap terminate_after_signal HUP INT TERM
trap rotate_event_source USR1

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
# reach the reader immediately. A checkpoint rotates the XI2 client itself:
# terminate the old source, drain all bytes it already published through EOF,
# and only then enqueue the checkpoint behind the old epoch's agent work. Any
# event still unread in the old X connection is discarded when that connection
# closes and therefore cannot consume the next arm.
mkfifo "${event_fifo}"
event_source_generation=0
start_event_source() {
    event_source_generation=$((event_source_generation + 1))
    source_ready="${monitor_state_root}/source-ready-${event_source_generation}"
    rm -f "${source_ready}"
    process_events < "${event_fifo}" &
    event_reader_pid=$!
    (
        if test -n "${PERF_MARKER_EVENT_SOURCE_COMMAND:-}"; then
            exec "${PERF_MARKER_EVENT_SOURCE_COMMAND}" \
                "${event_source_generation}" "${source_ready}"
        fi
        source_child=
        forward_source_signal() {
            trap - TERM
            if test -n "${source_child}"; then
                kill -TERM "${source_child}" 2>/dev/null || true
                wait "${source_child}" 2>/dev/null || true
            fi
            exit 0
        }
        trap forward_source_signal TERM
        stdbuf -oL -eL xinput test-xi2 --root &
        source_child=$!
        exec_attempt=0
        while true; do
            test "${exec_attempt}" -lt 500 || exit 1
            if ! kill -0 "${source_child}" 2>/dev/null; then
                wait "${source_child}"
                exit $?
            fi
            source_executable="$(readlink "/proc/${source_child}/exe" 2>/dev/null || true)"
            case "${source_executable}" in
                */xinput)
                    : > "${source_ready}"
                    break
                    ;;
            esac
            exec_attempt=$((exec_attempt + 1))
            sleep 0.01
        done
        wait "${source_child}"
    ) > "${event_fifo}" &
    event_source_pid=$!
    ready_attempt=0
    while ! test -f "${source_ready}"; do
        if ! kill -0 "${event_source_pid}" 2>/dev/null \
            || test "${ready_attempt}" -ge 500; then
            return 1
        fi
        ready_attempt=$((ready_attempt + 1))
        sleep 0.01
    done
    if test -n "${PERF_MARKER_MONITOR_BEFORE_SOURCE_READY_FILE:-}"; then
        source_gate="${PERF_MARKER_MONITOR_BEFORE_SOURCE_READY_FILE}"
        : > "${source_gate}.entered.${event_source_generation}"
        while ! test -e "${source_gate}.release.${event_source_generation}"; do
            sleep 0.01
        done
    fi
    rm -f "${source_ready}"
    if test "${PERF_MARKER_MONITOR_DIAGNOSTICS:-0}" = 1; then
        echo "PERF_INPUT_SOURCE_EPOCH generation=${event_source_generation}"
    fi
}

start_event_source
# Publish the signal target only after USR1 handling is installed and the
# initial XI2 subscription endpoint is established. A checkpoint cannot race
# the shell's default USR1 action or an uninitialized source PID.
printf '%s\n' "${monitor_pid}" > "${monitor_pid_file}"
while true; do
    source_status=0
    wait "${event_source_pid}" || source_status=$?
    event_source_pid=
    wait "${event_reader_pid}"
    event_reader_pid=

    if test "${rotate_requested}" = true && test -f "${checkpoint_request}"; then
        read -r invocation < "${checkpoint_request}"
        rm -f "${checkpoint_request}"
        valid_invocation "${invocation}" || exit 2
        # Establish the new XI2 subscription before acknowledging the epoch
        # checkpoint. The host cannot arm until the serialized worker reaches
        # this checkpoint, so no old-source event can be attributed forward.
        rotate_requested=false
        start_event_source
        printf '__checkpoint__ invocation=%s\n' "${invocation}" >&3
        continue
    fi
    test "${source_status}" -eq 0 || exit "${source_status}"
    break
done
printf '%s\n' __stop__ >&3
wait "${dispatcher_pid}"
dispatcher_pid=
