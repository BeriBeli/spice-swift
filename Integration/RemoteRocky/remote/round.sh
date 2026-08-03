#!/bin/bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

command="${1:-}"
run_dir="$(current_run_dir)"
require_running

case "${command}" in
    begin)
        label="${2:-capture}"
        if [[ ! "${label}" =~ ^[A-Za-z0-9._-]+$ ]]; then
            echo "Round label may contain only letters, digits, dot, underscore, and dash." >&2
            exit 2
        fi
        if [[ -f "${PERF_STATE}/round-start" ]]; then
            echo "A capture round is already active." >&2
            exit 1
        fi
        round_id="$(date -u +%Y%m%dT%H%M%SZ)-${label}"
        date -u +%Y-%m-%dT%H:%M:%SZ > "${PERF_STATE}/round-start"
        printf '%s\n' "${round_id}" > "${PERF_STATE}/round-id"
        printf 'round=%s state=begun\n' "${round_id}"
        ;;
    end)
        if [[ ! -f "${PERF_STATE}/round-start" || ! -f "${PERF_STATE}/round-id" ]]; then
            echo "No capture round is active." >&2
            exit 1
        fi
        started_at="$(<"${PERF_STATE}/round-start")"
        round_id="$(<"${PERF_STATE}/round-id")"
        round_log="${run_dir}/rounds/${round_id}-server.log"
        round_telemetry="${run_dir}/rounds/${round_id}-guest-telemetry.log"
        podman logs --since "${started_at}" "${PERF_CONTAINER}" > "${round_log}" 2>&1
        grep '^PERF_GENERATOR ' "${round_log}" > "${round_telemetry}" || true
        telemetry_samples="$(wc -l < "${round_telemetry}")"
        cp "${run_dir}/configuration.txt" "${run_dir}/rounds/${round_id}-configuration.txt"
        cp "${run_dir}/versions.txt" "${run_dir}/rounds/${round_id}-versions.txt"
        rm -f "${PERF_STATE}/round-start" "${PERF_STATE}/round-id"
        printf 'round=%s state=ended log=%s guest_telemetry=%s telemetry_samples=%d\n' \
            "${round_id}" \
            "${round_log}" \
            "${round_telemetry}" \
            "${telemetry_samples}"
        ;;
    *)
        echo "Usage: $0 begin [label] | end" >&2
        exit 2
        ;;
esac
