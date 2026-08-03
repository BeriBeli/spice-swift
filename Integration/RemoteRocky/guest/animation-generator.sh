#!/bin/sh

set -eu

parent_pid="${PPID}"
reset_requested=0
trap 'reset_requested=1' USR1

generation="${PERF_ANIMATION_GENERATION:-0}"
case "${generation}" in
    ''|*[!0-9]*) generation=0 ;;
esac
boot_epoch=unknown
IFS= read -r boot_epoch < /proc/sys/kernel/random/boot_id || boot_epoch=unknown

read_generation() {
    next_generation=0
    if IFS= read -r next_generation < /run/perf-animation-generation; then
        case "${next_generation}" in
            ''|*[!0-9]*) return 1 ;;
            *) generation="${next_generation}" ;;
        esac
    else
        return 1
    fi
}

emit_telemetry() {
    telemetry_event="$1"
    monotonic_uptime_seconds=unknown
    IFS=' ' read -r monotonic_uptime_seconds _ < /proc/uptime || true
    printf 'PERF_GENERATOR event=%s generation=%s frame_id=%s monotonic_uptime_seconds=%s pid=%s boot_epoch=%s\n' \
        "${telemetry_event}" \
        "${generation}" \
        "${frame}" \
        "${monotonic_uptime_seconds}" \
        "$$" \
        "${boot_epoch}" \
        2>/dev/null > /dev/console || true
}

frame=0
frames_since_telemetry=0
telemetry_event=start
printf '\033[2J'
while kill -0 "${parent_pid}" 2>/dev/null; do
    if test "${reset_requested}" -eq 1; then
        read_generation || generation=$((generation + 1))
        frame=0
        frames_since_telemetry=0
        telemetry_event=reset
        reset_requested=0
        printf '\033[2J'
    fi
    printf '\033[HSwiftSpice deterministic animation | 1280x720 | frame=%06d\n' "${frame}"
    row=0
    while test "${row}" -lt 32; do
        phase=$(((frame + row * 3) % 64))
        column=0
        while test "${column}" -lt 96; do
            distance=$(((column + 64 - phase) % 64))
            if test "${distance}" -lt 12; then
                printf '\033[48;5;39m '
            elif test "${distance}" -lt 24; then
                printf '\033[48;5;214m '
            elif test "${distance}" -lt 36; then
                printf '\033[48;5;197m '
            else
                printf '\033[48;5;235m '
            fi
            column=$((column + 1))
        done
        printf '\033[0m\n'
        row=$((row + 1))
    done
    frames_since_telemetry=$((frames_since_telemetry + 1))
    if test "${telemetry_event}" != heartbeat \
        || test "${frames_since_telemetry}" -ge 30; then
        emit_telemetry "${telemetry_event}"
        frames_since_telemetry=0
        telemetry_event=heartbeat
    fi
    frame=$((frame + 1))
    sleep 0.033333 || true
done
