#!/usr/bin/env bash
set -euo pipefail

# RUN_NUMBER and RENDERER are supplied by the benchmark runner for wrapper
# compatibility. The guest boot ID itself must not depend on either value.
readonly RUN_NUMBER="${1:-}"
readonly RENDERER="${2:-}"
if [[ -z "${RUN_NUMBER}" || -z "${RENDERER}" ]]; then
    echo "usage: $0 RUN_NUMBER RENDERER" >&2
    exit 2
fi

# Expanded by the remote login shell.
# shellcheck disable=SC2016
readonly REMOTE_BASE='$HOME/swiftspice-remote-closure/perf-ab/remote'
ssh -o BatchMode=yes rocky8 "$REMOTE_BASE/boot-epoch.sh"
