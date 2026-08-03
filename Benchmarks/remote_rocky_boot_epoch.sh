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
readonly DEFAULT_REMOTE_DIRECTORY='$HOME/swiftspice-remote-closure/perf-ab/remote'
readonly REMOTE_DIRECTORY="${SWIFTSPICE_BENCH_REMOTE_ROCKY_DIRECTORY:-$DEFAULT_REMOTE_DIRECTORY}"
if [[ "$REMOTE_DIRECTORY" != "$DEFAULT_REMOTE_DIRECTORY" \
    && ! "$REMOTE_DIRECTORY" =~ ^/[A-Za-z0-9._/-]+/remote$ ]]
then
    echo "invalid Rocky remote directory" >&2
    exit 2
fi
readonly REMOTE_FIXTURE_BASE="${REMOTE_DIRECTORY%/remote}"
ssh -o BatchMode=yes rocky8 \
    "SWIFTSPICE_PERF_BASE=\"$REMOTE_FIXTURE_BASE\" \"$REMOTE_DIRECTORY/boot-epoch.sh\""
