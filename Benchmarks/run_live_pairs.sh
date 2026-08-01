#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 5 ]]; then
    echo "usage: $0 HOST PORT RUNS OBSERVE_SECONDS OUTPUT_DIRECTORY" >&2
    exit 2
fi

readonly HOST="$1"
readonly PORT="$2"
readonly RUNS="$3"
readonly OBSERVE_SECONDS="$4"
readonly OUTPUT_DIRECTORY="$5"
readonly RESET_SCRIPT="${SWIFTSPICE_BENCH_RESET_SCRIPT:-}"
readonly HOOK_SCRIPT="${SWIFTSPICE_BENCH_HOOK_SCRIPT:-}"
readonly VIDEO_CODEC="${SWIFTSPICE_BENCH_VIDEO_CODEC:-mjpeg}"

if [[ -z "${SPICE_PASSWORD+x}" ]]; then
    echo "SPICE_PASSWORD must be set (an empty ticket is allowed)" >&2
    exit 2
fi
if [[ ! "$PORT" =~ ^[0-9]+$ ]] || ((PORT < 1 || PORT > 65535)); then
    echo "invalid PORT" >&2
    exit 2
fi
if [[ ! "$RUNS" =~ ^[0-9]+$ ]] || ((RUNS < 1)); then
    echo "invalid RUNS" >&2
    exit 2
fi
if [[ ! "$OBSERVE_SECONDS" =~ ^[0-9]+$ ]] || ((OBSERVE_SECONDS < 1)); then
    echo "invalid OBSERVE_SECONDS" >&2
    exit 2
fi
if [[ -n "$RESET_SCRIPT" && ! -x "$RESET_SCRIPT" ]]; then
    echo "SWIFTSPICE_BENCH_RESET_SCRIPT is not executable: $RESET_SCRIPT" >&2
    exit 2
fi
if [[ -n "$HOOK_SCRIPT" && ! -x "$HOOK_SCRIPT" ]]; then
    echo "SWIFTSPICE_BENCH_HOOK_SCRIPT is not executable: $HOOK_SCRIPT" >&2
    exit 2
fi
if [[ -e "$OUTPUT_DIRECTORY" ]]; then
    echo "output directory already exists: $OUTPUT_DIRECTORY" >&2
    exit 2
fi

SWIFT_VIDEO_FLAGS=()
case "$VIDEO_CODEC" in
    mjpeg)
        ;;
    h264)
        SWIFT_VIDEO_FLAGS=(--enable-h264 --require-native-video)
        ;;
    h265)
        SWIFT_VIDEO_FLAGS=(--enable-h265 --require-native-video)
        ;;
    *)
        echo "SWIFTSPICE_BENCH_VIDEO_CODEC must be mjpeg, h264, or h265" >&2
        exit 2
        ;;
esac

mkdir -p "$OUTPUT_DIRECTORY"

ROOT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIRECTORY
cd "$ROOT_DIRECTORY"

swift build --disable-sandbox -c release --product spice-probe
SWIFT_PROBE="$(swift build --disable-sandbox -c release --show-bin-path)/spice-probe"
readonly SWIFT_PROBE
readonly GLIB_PROBE="$OUTPUT_DIRECTORY/spice-glib-bench"
IFS=' ' read -r -a SPICE_GLIB_FLAGS <<< "$(pkg-config --cflags --libs spice-client-glib-2.0)"

cc -O2 -Wall -Wextra -Werror \
    Benchmarks/Reference/spice_glib_bench.c \
    "${SPICE_GLIB_FLAGS[@]}" \
    -framework CoreFoundation -framework IOSurface \
    -o "$GLIB_PROBE"

run_client() {
    local run_number="$1"
    local client="$2"
    local prefix
    prefix="$OUTPUT_DIRECTORY/run-$(printf '%02d' "$run_number")-$client"
    printf 'run=%02d client=%s state=starting\n' "$run_number" "$client"

    if [[ -n "$RESET_SCRIPT" ]]; then
        "$RESET_SCRIPT" "$run_number" "$client"
    fi
    if [[ -n "$HOOK_SCRIPT" ]]; then
        "$HOOK_SCRIPT" before "$run_number" "$client"
    fi

    local result=0
    set +e
    case "$client" in
        swiftspice)
            /usr/bin/time -lp -o "$prefix.time.txt" \
                "$SWIFT_PROBE" "$HOST" "$PORT" \
                --observe-seconds "$OBSERVE_SECONDS" --benchmark-json \
                ${SWIFT_VIDEO_FLAGS[@]+"${SWIFT_VIDEO_FLAGS[@]}"} \
                >"$prefix.json"
            ;;
        spice-client-glib2)
            /usr/bin/time -lp -o "$prefix.time.txt" \
                "$GLIB_PROBE" "$HOST" "$PORT" "$OBSERVE_SECONDS" \
                >"$prefix.json"
            ;;
        *)
            echo "unknown client: $client" >&2
            exit 2
            ;;
    esac
    result=$?
    set -e
    if [[ -n "$HOOK_SCRIPT" ]]; then
        "$HOOK_SCRIPT" after "$run_number" "$client"
    fi
    if ((result != 0)); then
        return "$result"
    fi
    jq -e '.frames >= 2' "$prefix.json" >/dev/null || {
        echo "inactive benchmark workload in $prefix.json" >&2
        return 1
    }
    if [[ "$client" == "swiftspice" && "$VIDEO_CODEC" != "mjpeg" ]]; then
        jq -e '
            .native_video_frames >= 1
            and .vt_decoded_frames >= 1
            and .vt_cpu_materializations == 0
            and .advanced_cpu_fallback_frames == 0
            and .gpu_errors == 0
            and .metal_generation_disables == 0
        ' "$prefix.json" >/dev/null || {
            echo "native-video evidence gate failed in $prefix.json" >&2
            return 1
        }
    fi
    printf 'run=%02d client=%s state=completed\n' "$run_number" "$client"
}

for ((run_number = 1; run_number <= RUNS; run_number++)); do
    if ((run_number % 2 == 1)); then
        run_client "$run_number" swiftspice
        run_client "$run_number" spice-client-glib2
    else
        run_client "$run_number" spice-client-glib2
        run_client "$run_number" swiftspice
    fi
done

printf 'results: %s\n' "$OUTPUT_DIRECTORY"
UV_CACHE_DIR="${UV_CACHE_DIR:-/private/tmp/swiftspice-uv-cache}" \
    uv run Benchmarks/analyze.py "$OUTPUT_DIRECTORY" --expected-pairs "$RUNS"
