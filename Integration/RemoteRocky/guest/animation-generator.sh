#!/bin/sh

set -eu

parent_pid="${PPID}"
reset_requested=0
trap 'reset_requested=1' USR1

frame=0
printf '\033[2J'
while kill -0 "${parent_pid}" 2>/dev/null; do
    if test "${reset_requested}" -eq 1; then
        frame=0
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
    frame=$(((frame + 1) % 1000000))
    sleep 0.033333 || true
done
