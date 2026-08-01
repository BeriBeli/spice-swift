#!/usr/bin/env bash
set -euo pipefail

readonly PHASE="$1"
readonly RUN_NUMBER="$2"
readonly CLIENT="$3"
# Expanded by the remote login shell.
# shellcheck disable=SC2016
readonly REMOTE_BASE='$HOME/swiftspice-remote-closure/perf-ab/remote'
LABEL="run-$(printf '%02d' "$RUN_NUMBER")-$CLIENT"
readonly LABEL

case "$PHASE" in
    before)
        ssh -o BatchMode=yes rocky8 "$REMOTE_BASE/round.sh begin '$LABEL'" >/dev/null
        if ! ssh -o BatchMode=yes rocky8 "$REMOTE_BASE/control.sh reset" >/dev/null; then
            ssh -o BatchMode=yes rocky8 "$REMOTE_BASE/round.sh end" >/dev/null 2>&1 || true
            exit 1
        fi
        ;;
    after)
        ssh -o BatchMode=yes rocky8 "$REMOTE_BASE/round.sh end" >/dev/null
        ;;
    *)
        echo "invalid hook phase: $PHASE" >&2
        exit 2
        ;;
esac
