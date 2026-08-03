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
readonly RENDERER="${SWIFTSPICE_BENCH_RENDERER:-metal}"
readonly BOOT_EPOCH="${SWIFTSPICE_BENCH_BOOT_EPOCH:-}"
readonly BOOT_EPOCH_SCRIPT="${SWIFTSPICE_BENCH_BOOT_EPOCH_SCRIPT:-}"
readonly CONTINUE_ON_FAILURE="${SWIFTSPICE_BENCH_CONTINUE_ON_FAILURE:-0}"

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
if [[ -n "$BOOT_EPOCH_SCRIPT" && ! -x "$BOOT_EPOCH_SCRIPT" ]]; then
    echo "SWIFTSPICE_BENCH_BOOT_EPOCH_SCRIPT is not executable: $BOOT_EPOCH_SCRIPT" >&2
    exit 2
fi
if [[ -n "$BOOT_EPOCH" && -n "$BOOT_EPOCH_SCRIPT" ]]; then
    echo "set only one of SWIFTSPICE_BENCH_BOOT_EPOCH or SWIFTSPICE_BENCH_BOOT_EPOCH_SCRIPT" >&2
    exit 2
fi
if [[ -z "$BOOT_EPOCH" && -z "$BOOT_EPOCH_SCRIPT" ]]; then
    echo "a guest boot epoch value or script is required" >&2
    exit 2
fi
if [[ "$CONTINUE_ON_FAILURE" != 0 && "$CONTINUE_ON_FAILURE" != 1 ]]; then
    echo "SWIFTSPICE_BENCH_CONTINUE_ON_FAILURE must be 0 or 1" >&2
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
case "$RENDERER" in
    automatic|cpu|cpu-iosurface|metal)
        ;;
    *)
        echo "SWIFTSPICE_BENCH_RENDERER must be automatic, cpu, cpu-iosurface, or metal" >&2
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
    local sample_boot_epoch="$BOOT_EPOCH"
    if [[ -n "$BOOT_EPOCH_SCRIPT" ]]; then
        sample_boot_epoch="$($BOOT_EPOCH_SCRIPT "$run_number" "$client")"
    fi
    if [[ -z "$sample_boot_epoch" || "$sample_boot_epoch" == *$'\n'* ]]; then
        echo "boot epoch must be one non-empty line" >&2
        return 1
    fi

    local result=0
    set +e
    case "$client" in
        swiftspice)
            /usr/bin/time -lp -o "$prefix.time.txt" \
                "$SWIFT_PROBE" "$HOST" "$PORT" \
                --observe-seconds "$OBSERVE_SECONDS" --benchmark-json \
                --renderer "$RENDERER" \
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
    jq -n \
        --arg boot_epoch "$sample_boot_epoch" \
        --arg client "$client" \
        --arg renderer "$RENDERER" \
        --arg video_codec "$VIDEO_CODEC" \
        --argjson exit_code "$result" \
        --argjson observe_seconds "$OBSERVE_SECONDS" \
        --argjson run "$run_number" \
        '{
            boot_epoch: $boot_epoch,
            client: $client,
            exit_code: $exit_code,
            observe_seconds: $observe_seconds,
            renderer: $renderer,
            run: $run,
            video_codec: $video_codec
        }' >"$prefix.meta.json"
    if [[ -n "$HOOK_SCRIPT" ]]; then
        "$HOOK_SCRIPT" after "$run_number" "$client"
    fi
    local sample_failed=0
    if ((result != 0)); then
        if [[ "$CONTINUE_ON_FAILURE" != 1 ]]; then
            return "$result"
        fi
        printf '%02d\t%s\texit_code=%d\n' "$run_number" "$client" "$result" \
            >>"$OUTPUT_DIRECTORY/integrity-failures.tsv"
        sample_failed=1
    fi
    if ((result == 0)) && ! jq -e --argjson observe_seconds "$OBSERVE_SECONDS" '
        .frames >= 2
        and .observe_seconds == $observe_seconds
        and .expected_time_buckets == 10
        and .active_time_buckets * 5 >= .expected_time_buckets * 4
        and .active_span_ms >= ($observe_seconds * 800)
        and .last_frame_age_ms >= 0
        and .last_frame_age_ms <= 1000
    ' "$prefix.json" >/dev/null; then
        echo "incomplete benchmark activity window in $prefix.json" >&2
        if [[ "$CONTINUE_ON_FAILURE" != 1 ]]; then
            return 1
        fi
        printf '%02d\t%s\tincomplete_activity\n' "$run_number" "$client" \
            >>"$OUTPUT_DIRECTORY/integrity-failures.tsv"
        sample_failed=1
    fi
    if ((result == 0)) && [[ "$client" == "swiftspice" ]]; then
        local renderer_evidence='false'
        case "$RENDERER" in
            automatic)
                renderer_evidence='
                    .renderer == $renderer
                    and .metal_2d_renderer_enabled == false
                    and .metal_2d_command_buffers == 0
                    and .metal_2d_commands == 0
                    and .pool_exhaustions == 0
                    and .gpu_errors == 0
                    and ((
                        .cpu_fill_operations
                        + .cpu_copy_bits_operations
                        + .cpu_bitmap_copy_operations
                        + .cpu_surface_copy_operations
                        + .cpu_scaled_copy_operations
                    ) >= 1)'
                ;;
            cpu)
                renderer_evidence='
                    .renderer == $renderer
                    and .revisioned_backing_enabled == false
                    and .metal_2d_renderer_enabled == false
                    and .metal_2d_command_buffers == 0
                    and .metal_2d_commands == 0
                    and .pool_exhaustions == 0
                    and .gpu_errors == 0
                    and ((
                        .cpu_fill_operations
                        + .cpu_copy_bits_operations
                        + .cpu_bitmap_copy_operations
                        + .cpu_surface_copy_operations
                        + .cpu_scaled_copy_operations
                    ) >= 1)'
                ;;
            cpu-iosurface)
                renderer_evidence='
                    .renderer == $renderer
                    and .revisioned_backing_enabled == true
                    and .revisioned_allocated_frames >= 1
                    and .metal_2d_renderer_enabled == false
                    and .metal_2d_command_buffers == 0
                    and .metal_2d_commands == 0
                    and .pool_exhaustions == 0
                    and .gpu_errors == 0
                    and ($video_codec != "mjpeg" or .cpu_materializations == 0)
                    and ((
                        .cpu_fill_operations
                        + .cpu_copy_bits_operations
                        + .cpu_bitmap_copy_operations
                        + .cpu_surface_copy_operations
                        + .cpu_scaled_copy_operations
                    ) >= 1)'
                ;;
            metal)
                renderer_evidence='
                    .renderer == $renderer
                    and .revisioned_backing_enabled == true
                    and .metal_2d_renderer_enabled == true
                    and .metal_2d_command_buffers >= 1
                    and .metal_2d_commands >= 1
                    and .cpu_materializations == 0
                    and .gpu_errors == 0
                    and .pool_exhaustions == 0
                    and .metal_2d_cpu_fallback_operations == 0
                    and .cpu_fill_operations == 0
                    and .cpu_copy_bits_operations == 0
                    and .cpu_bitmap_copy_operations == 0
                    and .cpu_surface_copy_operations == 0'
                ;;
        esac
        if ! jq -e \
            --arg renderer "$RENDERER" \
            --arg video_codec "$VIDEO_CODEC" \
            "$renderer_evidence" "$prefix.json" >/dev/null
        then
            echo "$RENDERER renderer evidence gate failed in $prefix.json" >&2
            if [[ "$CONTINUE_ON_FAILURE" != 1 ]]; then
                return 1
            fi
            printf '%02d\t%s\trenderer_evidence\n' "$run_number" "$client" \
                >>"$OUTPUT_DIRECTORY/integrity-failures.tsv"
            sample_failed=1
        fi
    fi
    if ((result == 0)) && [[ "$client" == "swiftspice" && "$VIDEO_CODEC" != "mjpeg" ]]; then
        if ! jq -e '
            .native_video_frames >= 1
            and .vt_decoded_frames >= 1
            and .vt_cpu_materializations == 0
            and .advanced_cpu_fallback_frames == 0
            and .gpu_errors == 0
            and .metal_generation_disables == 0
        ' "$prefix.json" >/dev/null; then
            echo "native-video evidence gate failed in $prefix.json" >&2
            if [[ "$CONTINUE_ON_FAILURE" != 1 ]]; then
                return 1
            fi
            printf '%02d\t%s\tnative_video_evidence\n' "$run_number" "$client" \
                >>"$OUTPUT_DIRECTORY/integrity-failures.tsv"
            sample_failed=1
        fi
    fi
    if ((sample_failed == 1)); then
        printf 'run=%02d client=%s state=completed-integrity-failed\n' "$run_number" "$client"
    else
        printf 'run=%02d client=%s state=completed\n' "$run_number" "$client"
    fi
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
