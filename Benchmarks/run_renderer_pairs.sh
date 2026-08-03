#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 5 ]]; then
    echo "usage: $0 HOST PORT PAIRS OBSERVE_SECONDS OUTPUT_DIRECTORY" >&2
    exit 2
fi

readonly HOST="$1"
readonly PORT="$2"
readonly PAIRS="$3"
readonly OBSERVE_SECONDS="$4"
OUTPUT_DIRECTORY="$5"
RESET_SCRIPT="${SWIFTSPICE_BENCH_RESET_SCRIPT:-}"
HOOK_SCRIPT="${SWIFTSPICE_BENCH_HOOK_SCRIPT:-}"
readonly VIDEO_CODEC="${SWIFTSPICE_BENCH_VIDEO_CODEC:-mjpeg}"
readonly RESOLUTION="${SWIFTSPICE_BENCH_RESOLUTION:-}"
readonly BOOT_EPOCH="${SWIFTSPICE_BENCH_BOOT_EPOCH:-}"
BOOT_EPOCH_SCRIPT="${SWIFTSPICE_BENCH_BOOT_EPOCH_SCRIPT:-}"
readonly CONTINUE_ON_FAILURE="${SWIFTSPICE_BENCH_CONTINUE_ON_FAILURE:-0}"

if [[ -z "${SPICE_PASSWORD+x}" ]]; then
    echo "SPICE_PASSWORD must be set (an empty ticket is allowed)" >&2
    exit 2
fi
if [[ ! "$PORT" =~ ^[0-9]+$ ]] || ((PORT < 1 || PORT > 65535)); then
    echo "invalid PORT" >&2
    exit 2
fi
if [[ ! "$PAIRS" =~ ^[0-9]+$ ]] || ((PAIRS < 1)); then
    echo "invalid PAIRS" >&2
    exit 2
fi
if [[ ! "$OBSERVE_SECONDS" =~ ^[0-9]+$ ]] || ((OBSERVE_SECONDS < 1)); then
    echo "invalid OBSERVE_SECONDS" >&2
    exit 2
fi
if [[ -z "$RESET_SCRIPT" && -z "$HOOK_SCRIPT" ]]; then
    echo "SWIFTSPICE_BENCH_RESET_SCRIPT or SWIFTSPICE_BENCH_HOOK_SCRIPT is required" >&2
    echo "when only the hook is set, its before phase must perform a deterministic reset" >&2
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
if [[ -n "$BOOT_EPOCH" ]]; then
    echo "direct renderer pairs require SWIFTSPICE_BENCH_BOOT_EPOCH_SCRIPT" >&2
    echo "a fixed SWIFTSPICE_BENCH_BOOT_EPOCH cannot prove sample-end continuity" >&2
    exit 2
fi
if [[ -z "$BOOT_EPOCH_SCRIPT" ]]; then
    echo "SWIFTSPICE_BENCH_BOOT_EPOCH_SCRIPT is required" >&2
    exit 2
fi
if [[ ! "$RESOLUTION" =~ ^([1-9][0-9]*)x([1-9][0-9]*)$ ]]; then
    echo "SWIFTSPICE_BENCH_RESOLUTION must be set to WIDTHxHEIGHT" >&2
    exit 2
fi
readonly RESOLUTION_WIDTH="${BASH_REMATCH[1]}"
readonly RESOLUTION_HEIGHT="${BASH_REMATCH[2]}"
if [[ "$CONTINUE_ON_FAILURE" != 0 && "$CONTINUE_ON_FAILURE" != 1 ]]; then
    echo "SWIFTSPICE_BENCH_CONTINUE_ON_FAILURE must be 0 or 1" >&2
    exit 2
fi
if [[ -e "$OUTPUT_DIRECTORY" ]]; then
    echo "output directory already exists: $OUTPUT_DIRECTORY" >&2
    exit 2
fi

if [[ -n "$RESET_SCRIPT" ]]; then
    readonly RESET_SOURCE="reset-script"
else
    readonly RESET_SOURCE="hook"
    echo "using the hook before phase as the deterministic reset source" >&2
fi
if [[ -n "$RESET_SCRIPT" && -n "$HOOK_SCRIPT" ]]; then
    echo "both reset and hook scripts are set; ensure the hook does not reset twice" >&2
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
OUTPUT_DIRECTORY="$(cd "$OUTPUT_DIRECTORY" && pwd)"
readonly OUTPUT_DIRECTORY
if [[ -n "$RESET_SCRIPT" ]]; then
    RESET_SCRIPT="$(cd "$(dirname "$RESET_SCRIPT")" && pwd)/$(basename "$RESET_SCRIPT")"
fi
readonly RESET_SCRIPT
if [[ -n "$HOOK_SCRIPT" ]]; then
    HOOK_SCRIPT="$(cd "$(dirname "$HOOK_SCRIPT")" && pwd)/$(basename "$HOOK_SCRIPT")"
fi
readonly HOOK_SCRIPT
BOOT_EPOCH_SCRIPT="$(cd "$(dirname "$BOOT_EPOCH_SCRIPT")" && pwd)/$(basename "$BOOT_EPOCH_SCRIPT")"
readonly BOOT_EPOCH_SCRIPT

ROOT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIRECTORY
cd "$ROOT_DIRECTORY"

swift build --disable-sandbox -c release --product spice-probe
SWIFT_PROBE="$(swift build --disable-sandbox -c release --show-bin-path)/spice-probe"
readonly SWIFT_PROBE

run_renderer() {
    local pair_number="$1"
    local renderer="$2"
    local sample_order="$3"
    local prefix
    prefix="$OUTPUT_DIRECTORY/pair-$(printf '%02d' "$pair_number")-$renderer"
    printf 'pair=%02d order=%d renderer=%s state=starting\n' \
        "$pair_number" "$sample_order" "$renderer"

    if [[ -n "$RESET_SCRIPT" ]]; then
        "$RESET_SCRIPT" "$pair_number" "$renderer"
    fi
    if [[ -n "$HOOK_SCRIPT" ]]; then
        "$HOOK_SCRIPT" before "$pair_number" "$renderer"
    fi
    local sample_boot_epoch=""
    local boot_epoch_start_result=0
    set +e
    sample_boot_epoch="$($BOOT_EPOCH_SCRIPT "$pair_number" "$renderer")"
    boot_epoch_start_result=$?
    set -e
    if ((boot_epoch_start_result != 0)) \
        || [[ -z "$sample_boot_epoch" \
            || "$sample_boot_epoch" == *$'\n'* \
            || "$sample_boot_epoch" == *$'\r'* ]]; then
        echo "start boot epoch must be one successful, non-empty line" >&2
        if [[ -n "$HOOK_SCRIPT" ]]; then
            "$HOOK_SCRIPT" after "$pair_number" "$renderer" >/dev/null 2>&1 || true
        fi
        return 1
    fi

    local result=0
    set +e
    /usr/bin/time -lp -o "$prefix.time.txt" \
        "$SWIFT_PROBE" "$HOST" "$PORT" \
        --observe-seconds "$OBSERVE_SECONDS" --benchmark-json \
        --renderer "$renderer" \
        ${SWIFT_VIDEO_FLAGS[@]+"${SWIFT_VIDEO_FLAGS[@]}"} \
        >"$prefix.json"
    result=$?
    set -e

    local sample_boot_epoch_end=""
    local boot_epoch_end_result=0
    set +e
    sample_boot_epoch_end="$($BOOT_EPOCH_SCRIPT "$pair_number" "$renderer")"
    boot_epoch_end_result=$?
    set -e

    local hook_after_result=0
    if [[ -n "$HOOK_SCRIPT" ]]; then
        set +e
        "$HOOK_SCRIPT" after "$pair_number" "$renderer"
        hook_after_result=$?
        set -e
    fi
    jq -n \
        --arg boot_epoch "$sample_boot_epoch" \
        --arg boot_epoch_end "$sample_boot_epoch_end" \
        --arg client "swiftspice" \
        --arg deterministic_reset_source "$RESET_SOURCE" \
        --arg requested_renderer "$renderer" \
        --arg resolution "$RESOLUTION" \
        --arg video_codec "$VIDEO_CODEC" \
        --argjson boot_epoch_end_exit_code "$boot_epoch_end_result" \
        --argjson exit_code "$result" \
        --argjson hook_after_exit_code "$hook_after_result" \
        --argjson observe_seconds "$OBSERVE_SECONDS" \
        --argjson pair "$pair_number" \
        --argjson sample_order "$sample_order" \
        '{
            boot_epoch: $boot_epoch,
            boot_epoch_end: $boot_epoch_end,
            boot_epoch_end_exit_code: $boot_epoch_end_exit_code,
            client: $client,
            deterministic_reset_source: $deterministic_reset_source,
            exit_code: $exit_code,
            hook_after_exit_code: $hook_after_exit_code,
            observe_seconds: $observe_seconds,
            pair: $pair,
            requested_renderer: $requested_renderer,
            resolution: $resolution,
            sample_order: $sample_order,
            video_codec: $video_codec
        }' >"$prefix.meta.json"

    local sample_failed=0
    if ((result != 0)); then
        if [[ "$CONTINUE_ON_FAILURE" != 1 ]]; then
            return "$result"
        fi
        printf '%02d\t%s\texit_code=%d\n' "$pair_number" "$renderer" "$result" \
            >>"$OUTPUT_DIRECTORY/integrity-failures.tsv"
        sample_failed=1
    fi
    if ((hook_after_result != 0)); then
        if [[ "$CONTINUE_ON_FAILURE" != 1 ]]; then
            return "$hook_after_result"
        fi
        printf '%02d\t%s\thook_after_exit_code=%d\n' \
            "$pair_number" "$renderer" "$hook_after_result" \
            >>"$OUTPUT_DIRECTORY/integrity-failures.tsv"
        sample_failed=1
    fi
    if ((boot_epoch_end_result != 0)) \
        || [[ -z "$sample_boot_epoch_end" \
            || "$sample_boot_epoch_end" == *$'\n'* \
            || "$sample_boot_epoch_end" == *$'\r'* \
            || "$sample_boot_epoch_end" != "$sample_boot_epoch" ]]; then
        echo "boot epoch changed or became unavailable during $prefix" >&2
        if [[ "$CONTINUE_ON_FAILURE" != 1 ]]; then
            return 1
        fi
        printf '%02d\t%s\tboot_epoch_continuity\n' "$pair_number" "$renderer" \
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
        printf '%02d\t%s\tincomplete_activity\n' "$pair_number" "$renderer" \
            >>"$OUTPUT_DIRECTORY/integrity-failures.tsv"
        sample_failed=1
    fi
    if ((result == 0)) && ! jq -e \
        --argjson height "$RESOLUTION_HEIGHT" \
        --argjson width "$RESOLUTION_WIDTH" '
        (.frames | type) == "number"
        and (.frame_bytes | type) == "number"
        and .frame_bytes == (.frames * $width * $height * 4)
    ' "$prefix.json" >/dev/null; then
        echo "resolution evidence gate failed in $prefix.json" >&2
        if [[ "$CONTINUE_ON_FAILURE" != 1 ]]; then
            return 1
        fi
        printf '%02d\t%s\tresolution_evidence\n' "$pair_number" "$renderer" \
            >>"$OUTPUT_DIRECTORY/integrity-failures.tsv"
        sample_failed=1
    fi
    if ((result == 0)); then
        local renderer_evidence='false'
        case "$renderer" in
            cpu-iosurface)
                # shellcheck disable=SC2016 # jq variables are supplied with --arg.
                renderer_evidence='
                    .renderer == $renderer
                    and .revisioned_backing_enabled == true
                    and .revisioned_allocated_frames >= 1
                    and .metal_2d_renderer_enabled == false
                    and .metal_2d_command_buffers == 0
                    and .metal_2d_commands == 0
                    and .pool_exhaustions == 0
                    and .gpu_errors == 0
                    and .cpu_materializations == 0
                    and ((
                        .cpu_fill_operations
                        + .cpu_copy_bits_operations
                        + .cpu_bitmap_copy_operations
                        + .cpu_surface_copy_operations
                        + .cpu_scaled_copy_operations
                    ) >= 1)'
                ;;
            metal)
                # shellcheck disable=SC2016 # jq variables are supplied with --arg.
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
                    and .cpu_surface_copy_operations == 0
                    and .cpu_scaled_copy_operations == 0'
                ;;
            *)
                echo "unknown direct-pair renderer: $renderer" >&2
                return 2
                ;;
        esac
        if ! jq -e \
            --arg renderer "$renderer" \
            --arg video_codec "$VIDEO_CODEC" \
            "$renderer_evidence" "$prefix.json" >/dev/null
        then
            echo "$renderer renderer evidence gate failed in $prefix.json" >&2
            if [[ "$CONTINUE_ON_FAILURE" != 1 ]]; then
                return 1
            fi
            printf '%02d\t%s\trenderer_evidence\n' "$pair_number" "$renderer" \
                >>"$OUTPUT_DIRECTORY/integrity-failures.tsv"
            sample_failed=1
        fi
    fi
    if ((result == 0)) && [[ "$VIDEO_CODEC" != "mjpeg" ]]; then
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
            printf '%02d\t%s\tnative_video_evidence\n' "$pair_number" "$renderer" \
                >>"$OUTPUT_DIRECTORY/integrity-failures.tsv"
            sample_failed=1
        fi
    fi
    if ((sample_failed == 1)); then
        printf 'pair=%02d order=%d renderer=%s state=completed-integrity-failed\n' \
            "$pair_number" "$sample_order" "$renderer"
    else
        printf 'pair=%02d order=%d renderer=%s state=completed\n' \
            "$pair_number" "$sample_order" "$renderer"
    fi
}

for ((pair_number = 1; pair_number <= PAIRS; pair_number++)); do
    if ((pair_number % 2 == 1)); then
        run_renderer "$pair_number" cpu-iosurface 1
        run_renderer "$pair_number" metal 2
    else
        run_renderer "$pair_number" metal 1
        run_renderer "$pair_number" cpu-iosurface 2
    fi
done

printf 'results: %s\n' "$OUTPUT_DIRECTORY"
UV_CACHE_DIR="${UV_CACHE_DIR:-/private/tmp/swiftspice-uv-cache}" \
    uv run Benchmarks/analyze_renderer_pairs.py \
        "$OUTPUT_DIRECTORY" --expected-pairs "$PAIRS"
