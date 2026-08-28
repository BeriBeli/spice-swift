#!/bin/sh

set -eu

request_fifo="${PERF_MARKER_REQUEST_FIFO:-/run/perf-marker-request}"
ack_fifo="${PERF_MARKER_ACK_FIFO:-/run/perf-marker-ack}"

if test "${1:-}" = terminal; then
    while true; do
        if read -r marker token_field revision_field checksum_field < "${request_fifo}"; then
            token="${token_field#token=}"
            revision="${revision_field#marker_revision=}"
            checksum="${checksum_field#checksum=}"
            test "${marker}" = SWIFTSPICE_MARKER || continue
            printf '\033[2J\033[H\033[30;107mCAUSAL INPUT MARKER\n'
            printf 'token=%s\nmarker_revision=%s checksum=%s\033[0m\n' \
                "${token}" "${revision}" "${checksum}"
            printf '%s\n' "${revision}" > "${ack_fifo}"
        fi
    done
fi

exec xterm \
    -geometry 48x4+0+0 \
    -bg '#ffffff' \
    -fg '#000000' \
    -fa 'DejaVu Sans Mono' \
    -fs 18 \
    -title 'SwiftSpice causal input marker' \
    -e "$0" terminal
