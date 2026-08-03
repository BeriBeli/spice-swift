#!/usr/bin/env bash
set -euo pipefail

readonly PHASE="$1"
readonly RUN_NUMBER="$2"
readonly CLIENT="$3"
# Expanded by the remote login shell.
# shellcheck disable=SC2016
readonly DEFAULT_REMOTE_DIRECTORY='$HOME/swiftspice-remote-closure/perf-ab/remote'
readonly REMOTE_DIRECTORY="${SWIFTSPICE_BENCH_REMOTE_ROCKY_DIRECTORY:-$DEFAULT_REMOTE_DIRECTORY}"
readonly ROUND_EVIDENCE_DIRECTORY="${SWIFTSPICE_BENCH_ROUND_EVIDENCE_DIRECTORY:-}"
if [[ "$REMOTE_DIRECTORY" != "$DEFAULT_REMOTE_DIRECTORY" \
    && ! "$REMOTE_DIRECTORY" =~ ^/[A-Za-z0-9._/-]+/remote$ ]]
then
    echo "invalid Rocky remote directory" >&2
    exit 2
fi
readonly REMOTE_FIXTURE_BASE="${REMOTE_DIRECTORY%/remote}"
LABEL="run-$(printf '%02d' "$RUN_NUMBER")-$CLIENT"
readonly LABEL

case "$PHASE" in
    before)
        ssh -o BatchMode=yes rocky8 \
            "SWIFTSPICE_PERF_BASE=\"$REMOTE_FIXTURE_BASE\" \"$REMOTE_DIRECTORY/round.sh\" begin '$LABEL'" \
            >/dev/null
        if ! ssh -o BatchMode=yes rocky8 \
            "SWIFTSPICE_PERF_BASE=\"$REMOTE_FIXTURE_BASE\" \"$REMOTE_DIRECTORY/control.sh\" reset" \
            >/dev/null
        then
            ssh -o BatchMode=yes rocky8 \
                "SWIFTSPICE_PERF_BASE=\"$REMOTE_FIXTURE_BASE\" \"$REMOTE_DIRECTORY/round.sh\" end" \
                >/dev/null 2>&1 || true
            exit 1
        fi
        ;;
    after)
        ROUND_RESULT="$(ssh -o BatchMode=yes rocky8 \
            "SWIFTSPICE_PERF_BASE=\"$REMOTE_FIXTURE_BASE\" \"$REMOTE_DIRECTORY/round.sh\" end" \
        )"
        readonly ROUND_RESULT
        if [[ -n "$ROUND_EVIDENCE_DIRECTORY" ]]; then
            ROUND_TOKEN="${ROUND_RESULT%% *}"
            ROUND_ID="${ROUND_TOKEN#round=}"
            readonly ROUND_TOKEN ROUND_ID
            if [[ ! "$ROUND_ID" =~ ^[0-9]{8}T[0-9]{6}Z-run-[0-9]{2}-[A-Za-z0-9._-]+$ ]] \
                || [[ "$ROUND_ID" != *"-$LABEL" ]]
            then
                echo "invalid or mismatched completed round ID" >&2
                exit 1
            fi

            ROUND_LOG=""
            ROUND_TELEMETRY=""
            read -r -a ROUND_FIELDS <<< "$ROUND_RESULT"
            for field in "${ROUND_FIELDS[@]}"; do
                case "$field" in
                    log=*) ROUND_LOG="${field#log=}" ;;
                    guest_telemetry=*) ROUND_TELEMETRY="${field#guest_telemetry=}" ;;
                esac
            done
            readonly ROUND_LOG ROUND_TELEMETRY
            if [[ ! "$ROUND_LOG" =~ ^/[A-Za-z0-9._/-]+/$ROUND_ID-server\.log$ \
                || ! "$ROUND_TELEMETRY" =~ ^/[A-Za-z0-9._/-]+/$ROUND_ID-guest-telemetry\.log$ ]]
            then
                echo "invalid completed round evidence paths" >&2
                exit 1
            fi
            readonly ROUND_PREFIX="${ROUND_LOG%-server.log}"
            mkdir -p "$ROUND_EVIDENCE_DIRECTORY"
            scp -q \
                "rocky8:$ROUND_LOG" \
                "rocky8:$ROUND_TELEMETRY" \
                "rocky8:$ROUND_PREFIX-configuration.txt" \
                "rocky8:$ROUND_PREFIX-versions.txt" \
                "$ROUND_EVIDENCE_DIRECTORY/"
        fi
        ;;
    *)
        echo "invalid hook phase: $PHASE" >&2
        exit 2
        ;;
esac
