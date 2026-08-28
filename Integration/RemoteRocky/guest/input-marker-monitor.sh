#!/bin/sh

set -eu
set -o pipefail
export LC_ALL=C

match_action_class() {
    case "$1" in
        *'(RawKeyPress)'*|*'(KeyPress)'*) echo key ;;
        *'(RawButtonPress)'*|*'(ButtonPress)'*) echo click ;;
        *'(RawMotion)'*|*'(Motion)'*) echo motion ;;
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

# xinput uses block buffering when stdout is a pipe. Force each event record to
# reach the state machine immediately; otherwise a live input can remain in the
# stdio buffer indefinitely while the long-running monitor stays connected.
stdbuf -oL -eL xinput test-xi2 --root | while IFS= read -r line; do
    if action_class="$(match_action_class "${line}")"; then
        /usr/local/bin/input-marker-agent.sh input "${action_class}"
    fi
done
