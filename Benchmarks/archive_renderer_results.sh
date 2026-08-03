#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
    echo "usage: $0 OUTPUT.tar.gz TESTED_GIT_REF RESULT_DIRECTORY [...]" >&2
    exit 2
fi

readonly OUTPUT="$1"
readonly TESTED_REF="$2"
shift 2

for required_command in git gzip jq mv rg sed shasum tar uv; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        echo "required command is unavailable: $required_command" >&2
        exit 2
    fi
done

OUTPUT_BASENAME="$(basename "$OUTPUT")"
readonly OUTPUT_BASENAME
if [[ ! "$OUTPUT_BASENAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.tar\.gz$ ]]; then
    echo "unsafe output basename: $OUTPUT_BASENAME" >&2
    exit 2
fi
if [[ -e "$OUTPUT" || -L "$OUTPUT" ]]; then
    echo "output already exists: $OUTPUT" >&2
    exit 2
fi

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIRECTORY
ROOT_DIRECTORY="$(git -C "$SCRIPT_DIRECTORY/.." rev-parse --show-toplevel)"
readonly ROOT_DIRECTORY
readonly ARCHIVE_TOOL="$ROOT_DIRECTORY/Benchmarks/archive_renderer_results.sh"
readonly GUEST_TELEMETRY_ANALYZER="$ROOT_DIRECTORY/Benchmarks/analyze_guest_telemetry.py"
for current_tool in "$ARCHIVE_TOOL" "$GUEST_TELEMETRY_ANALYZER"; do
    if [[ ! -f "$current_tool" || -L "$current_tool" ]]; then
        echo "current archive dependency is not a regular file: $current_tool" >&2
        exit 2
    fi
done

TESTED_HEAD="$(git -C "$ROOT_DIRECTORY" rev-parse "$TESTED_REF^{commit}")"
readonly TESTED_HEAD
TESTED_COMMIT_TIME="$(git -C "$ROOT_DIRECTORY" show -s --format=%cI "$TESTED_HEAD")"
readonly TESTED_COMMIT_TIME
COMMON_ANALYZER_BLOB="$(git -C "$ROOT_DIRECTORY" rev-parse \
    "$TESTED_HEAD:Benchmarks/analyze.py")"
readonly COMMON_ANALYZER_BLOB
RENDERER_ANALYZER_BLOB="$(git -C "$ROOT_DIRECTORY" rev-parse \
    "$TESTED_HEAD:Benchmarks/analyze_renderer_pairs.py")"
readonly RENDERER_ANALYZER_BLOB
RENDERER_RUNNER_BLOB="$(git -C "$ROOT_DIRECTORY" rev-parse \
    "$TESTED_HEAD:Benchmarks/run_renderer_pairs.sh")"
readonly RENDERER_RUNNER_BLOB

OUTPUT_PARENT="$(cd "$(dirname "$OUTPUT")" && pwd)"
readonly OUTPUT_PARENT
readonly OUTPUT_PATH="$OUTPUT_PARENT/$OUTPUT_BASENAME"
if [[ -e "$OUTPUT_PATH" || -L "$OUTPUT_PATH" ]]; then
    echo "output already exists: $OUTPUT_PATH" >&2
    exit 2
fi

created_work_directory="$(
    mktemp -d "${TMPDIR:-/private/tmp}/swiftspice-renderer-evidence.XXXXXX"
)"
WORK_DIRECTORY="$(cd "$created_work_directory" && pwd -P)"
readonly WORK_DIRECTORY
readonly ARCHIVE_ROOT="$WORK_DIRECTORY/swiftspice-benchmark-evidence"
trap 'rm -rf "$WORK_DIRECTORY"' EXIT

mkdir -p "$ARCHIVE_ROOT/results" "$ARCHIVE_ROOT/tools"
git -C "$ROOT_DIRECTORY" show "$TESTED_HEAD:Benchmarks/analyze.py" \
    >"$ARCHIVE_ROOT/tools/analyze.py"
git -C "$ROOT_DIRECTORY" show \
    "$TESTED_HEAD:Benchmarks/analyze_renderer_pairs.py" \
    >"$ARCHIVE_ROOT/tools/analyze_renderer_pairs.py"
git -C "$ROOT_DIRECTORY" show \
    "$TESTED_HEAD:Benchmarks/run_renderer_pairs.sh" \
    >"$ARCHIVE_ROOT/tools/run_renderer_pairs.sh"
cp "$GUEST_TELEMETRY_ANALYZER" "$ARCHIVE_ROOT/tools/"
cp "$ARCHIVE_TOOL" "$ARCHIVE_ROOT/tools/"

sha256_of() {
    shasum -a 256 "$1" | awk '{print $1}'
}

COMMON_ANALYZER_SHA256="$(sha256_of "$ARCHIVE_ROOT/tools/analyze.py")"
readonly COMMON_ANALYZER_SHA256
RENDERER_ANALYZER_SHA256="$(
    sha256_of "$ARCHIVE_ROOT/tools/analyze_renderer_pairs.py"
)"
readonly RENDERER_ANALYZER_SHA256
RENDERER_RUNNER_SHA256="$(
    sha256_of "$ARCHIVE_ROOT/tools/run_renderer_pairs.sh"
)"
readonly RENDERER_RUNNER_SHA256
GUEST_TELEMETRY_ANALYZER_SHA256="$(
    sha256_of "$ARCHIVE_ROOT/tools/analyze_guest_telemetry.py"
)"
readonly GUEST_TELEMETRY_ANALYZER_SHA256
ARCHIVE_TOOL_SHA256="$(
    sha256_of "$ARCHIVE_ROOT/tools/archive_renderer_results.sh"
)"
readonly ARCHIVE_TOOL_SHA256

USED_HOOK_JSON='null'
if [[ -n "${SWIFTSPICE_ARCHIVE_USED_HOOK+x}" ]]; then
    if [[ -z "$SWIFTSPICE_ARCHIVE_USED_HOOK" \
        || ! -f "$SWIFTSPICE_ARCHIVE_USED_HOOK" \
        || -L "$SWIFTSPICE_ARCHIVE_USED_HOOK" ]]
    then
        echo "SWIFTSPICE_ARCHIVE_USED_HOOK is not a regular file" >&2
        exit 2
    fi
    cp "$SWIFTSPICE_ARCHIVE_USED_HOOK" "$ARCHIVE_ROOT/tools/used-hook.sh"
    used_hook_sha256="$(sha256_of "$ARCHIVE_ROOT/tools/used-hook.sh")"
    USED_HOOK_JSON="$(jq -n \
        --arg archived_as "tools/used-hook.sh" \
        --arg sha256 "$used_hook_sha256" \
        '{archived_as: $archived_as, sha256: $sha256}')"
fi
readonly USED_HOOK_JSON

USED_BOOT_EPOCH_JSON='null'
if [[ -n "${SWIFTSPICE_ARCHIVE_USED_BOOT_EPOCH+x}" ]]; then
    if [[ -z "$SWIFTSPICE_ARCHIVE_USED_BOOT_EPOCH" \
        || ! -f "$SWIFTSPICE_ARCHIVE_USED_BOOT_EPOCH" \
        || -L "$SWIFTSPICE_ARCHIVE_USED_BOOT_EPOCH" ]]
    then
        echo "SWIFTSPICE_ARCHIVE_USED_BOOT_EPOCH is not a regular file" >&2
        exit 2
    fi
    cp "$SWIFTSPICE_ARCHIVE_USED_BOOT_EPOCH" \
        "$ARCHIVE_ROOT/tools/used-boot-epoch.sh"
    used_boot_epoch_sha256="$(
        sha256_of "$ARCHIVE_ROOT/tools/used-boot-epoch.sh"
    )"
    USED_BOOT_EPOCH_JSON="$(jq -n \
        --arg archived_as "tools/used-boot-epoch.sh" \
        --arg sha256 "$used_boot_epoch_sha256" \
        '{archived_as: $archived_as, sha256: $sha256}')"
fi
readonly USED_BOOT_EPOCH_JSON

readonly RESULT_MANIFEST_LINES="$WORK_DIRECTORY/result-sets.jsonl"
: >"$RESULT_MANIFEST_LINES"

for result_directory_argument in "$@"; do
    if [[ ! -d "$result_directory_argument" || -L "$result_directory_argument" ]]; then
        echo "result directory is not a regular directory: $result_directory_argument" >&2
        exit 2
    fi
    result_directory="$(cd "$result_directory_argument" && pwd -P)"
    result_name="$(basename "$result_directory")"
    if [[ ! "$result_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        echo "unsafe result directory name: $result_name" >&2
        exit 2
    fi
    destination="$ARCHIVE_ROOT/results/$result_name"
    if [[ -e "$destination" || -L "$destination" ]]; then
        echo "duplicate result directory basename: $result_name" >&2
        exit 2
    fi

    shopt -s nullglob
    sample_candidates=("$result_directory"/pair-*)
    metadata_files=("$result_directory"/pair-*.meta.json)
    shopt -u nullglob
    if ((${#metadata_files[@]} == 0)); then
        echo "no direct renderer metadata in: $result_directory" >&2
        exit 2
    fi
    if ((${#sample_candidates[@]} != ${#metadata_files[@]} * 3)); then
        echo "direct renderer sample files are incomplete or unexpected in: $result_directory" >&2
        exit 2
    fi
    for sample_candidate in "${sample_candidates[@]}"; do
        sample_basename="$(basename "$sample_candidate")"
        if [[ ! "$sample_basename" =~ ^pair-[0-9]{2}-(cpu-iosurface|metal)\.(json|meta\.json|time\.txt)$ ]]; then
            echo "unexpected direct renderer sample name: $sample_candidate" >&2
            exit 2
        fi
        if [[ ! -f "$sample_candidate" || -L "$sample_candidate" ]]; then
            echo "sample is not a regular file: $sample_candidate" >&2
            exit 2
        fi
    done

    highest_pair=0
    for metadata_file in "${metadata_files[@]}"; do
        metadata_basename="$(basename "$metadata_file")"
        if [[ ! "$metadata_basename" =~ ^pair-([0-9]{2})-(cpu-iosurface|metal)\.meta\.json$ ]]; then
            echo "invalid direct renderer metadata name: $metadata_file" >&2
            exit 2
        fi
        pair_text="${BASH_REMATCH[1]}"
        renderer="${BASH_REMATCH[2]}"
        pair_number=$((10#$pair_text))
        if ((pair_number < 1)); then
            echo "direct renderer pair numbers must start at 01: $metadata_file" >&2
            exit 2
        fi
        if ! jq -e \
            --arg renderer "$renderer" \
            --argjson pair "$pair_number" '
                type == "object"
                and .client == "swiftspice"
                and .pair == $pair
                and .requested_renderer == $renderer
                and (.observe_seconds | type) == "number"
                and .observe_seconds >= 1
                and (.observe_seconds | floor) == .observe_seconds
            ' "$metadata_file" >/dev/null
        then
            echo "invalid direct renderer metadata identity: $metadata_file" >&2
            exit 2
        fi
        if ((pair_number > highest_pair)); then
            highest_pair="$pair_number"
        fi
    done
    pair_count="$highest_pair"
    if ((${#metadata_files[@]} != pair_count * 2)); then
        echo "direct renderer metadata does not form contiguous pairs in: $result_directory" >&2
        exit 2
    fi

    observe_values_file="$WORK_DIRECTORY/$result_name-observe-seconds.txt"
    jq -r '.observe_seconds' "${metadata_files[@]}" \
        | LC_ALL=C sort -nu >"$observe_values_file"
    observe_value_count="$(wc -l <"$observe_values_file" | tr -d '[:space:]')"
    if [[ "$observe_value_count" != 1 ]]; then
        echo "mixed observation durations in: $result_directory" >&2
        exit 2
    fi
    observe_seconds="$(sed -n '1p' "$observe_values_file")"

    round_directory="$result_directory/remote-rounds"
    if [[ ! -d "$round_directory" || -L "$round_directory" ]]; then
        echo "remote-rounds is not a regular directory: $round_directory" >&2
        exit 2
    fi
    canonical_round_directory="$(cd "$round_directory" && pwd -P)"
    if [[ "$canonical_round_directory" != "$round_directory" ]]; then
        echo "remote-rounds escapes its result directory: $round_directory" >&2
        exit 2
    fi

    mkdir -p "$destination/remote-rounds"
    for ((pair_number = 1; pair_number <= pair_count; pair_number++)); do
        pair_text="$(printf '%02d' "$pair_number")"
        for renderer in cpu-iosurface metal; do
            prefix="$result_directory/pair-$pair_text-$renderer"
            for suffix in json meta.json time.txt; do
                sample_file="$prefix.$suffix"
                if [[ ! -f "$sample_file" || -L "$sample_file" ]]; then
                    echo "missing regular direct renderer sample: $sample_file" >&2
                    exit 2
                fi
                cp "$sample_file" "$destination/"
            done
            round_prefix=""
            for round_suffix in \
                server.log configuration.txt versions.txt guest-telemetry.log
            do
                round_file=""
                round_file_count=0
                for round_file_candidate in \
                    "$round_directory/"*"-run-$pair_text-$renderer-$round_suffix" \
                    "$round_directory/"*"-direct-pair-$pair_text-$renderer-$round_suffix"
                do
                    if [[ -e "$round_file_candidate" || -L "$round_file_candidate" ]]; then
                        round_file="$round_file_candidate"
                        ((round_file_count += 1))
                    fi
                done
                if ((round_file_count != 1)); then
                    echo "expected one run/direct-pair $round_suffix for pair $pair_text $renderer in $result_directory/remote-rounds" >&2
                    exit 2
                fi
                if [[ "$round_suffix" == server.log ]]; then
                    round_prefix="${round_file%-server.log}"
                elif [[ "$round_file" != "$round_prefix-$round_suffix" ]]; then
                    echo "mixed completed round evidence for pair $pair_text $renderer" >&2
                    exit 2
                fi
                round_basename="$(basename "$round_file")"
                if [[ ! "$round_basename" =~ ^[A-Za-z0-9._-]+$ \
                    || ! -f "$round_file" \
                    || -L "$round_file" ]]
                then
                    echo "unsafe or non-regular remote round evidence: $round_file" >&2
                    exit 2
                fi
                cp "$round_file" "$destination/remote-rounds/"
            done
        done
    done
    if [[ -e "$result_directory/integrity-failures.tsv" \
        || -L "$result_directory/integrity-failures.tsv" ]]
    then
        if [[ ! -f "$result_directory/integrity-failures.tsv" \
            || -L "$result_directory/integrity-failures.tsv" ]]
        then
            echo "integrity-failures.tsv is not a regular file: $result_directory" >&2
            exit 2
        fi
        cp "$result_directory/integrity-failures.tsv" "$destination/"
    fi
    fixture_manifest_present=false
    if [[ -e "$result_directory/fixture-manifest.json" \
        || -L "$result_directory/fixture-manifest.json" ]]
    then
        if [[ ! -f "$result_directory/fixture-manifest.json" \
            || -L "$result_directory/fixture-manifest.json" ]]
        then
            echo "fixture-manifest.json is not a regular file: $result_directory" >&2
            exit 2
        fi
        if ! jq -e 'type == "object"' \
            "$result_directory/fixture-manifest.json" >/dev/null
        then
            echo "fixture-manifest.json is not a JSON object: $result_directory" >&2
            exit 2
        fi
        cp "$result_directory/fixture-manifest.json" "$destination/"
        fixture_manifest_present=true
    fi

    set +e
    (
        cd "$ARCHIVE_ROOT"
        PYTHONDONTWRITEBYTECODE=1 \
        UV_CACHE_DIR="${UV_CACHE_DIR:-/private/tmp/swiftspice-renderer-archive-uv-cache}" \
            uv run tools/analyze_renderer_pairs.py \
                "results/$result_name" --json --expected-pairs "$pair_count"
    ) >"$destination/renderer-analyzer-output.txt" 2>&1
    renderer_analyzer_exit_code=$?
    (
        cd "$ARCHIVE_ROOT"
        PYTHONDONTWRITEBYTECODE=1 \
        UV_CACHE_DIR="${UV_CACHE_DIR:-/private/tmp/swiftspice-renderer-archive-uv-cache}" \
            uv run tools/analyze_guest_telemetry.py \
                "results/$result_name" \
                "results/$result_name/remote-rounds" \
                --expected-pairs "$pair_count" \
                --observe-seconds "$observe_seconds"
    ) >"$destination/guest-telemetry-analyzer-output.txt" 2>&1
    guest_telemetry_analyzer_exit_code=$?
    set -e
    for analyzer_output in \
        "$destination/renderer-analyzer-output.txt" \
        "$destination/guest-telemetry-analyzer-output.txt"
    do
        normalized_analyzer_output="$WORK_DIRECTORY/normalized-analyzer-output.txt"
        sed "s#$WORK_DIRECTORY#<archive-workdir>#g" \
            "$analyzer_output" >"$normalized_analyzer_output"
        mv "$normalized_analyzer_output" "$analyzer_output"
    done
    printf '%d\n' "$renderer_analyzer_exit_code" \
        >"$destination/renderer-analyzer-exit-code.txt"
    printf '%d\n' "$guest_telemetry_analyzer_exit_code" \
        >"$destination/guest-telemetry-analyzer-exit-code.txt"

    jq -n \
        --arg name "$result_name" \
        --argjson fixture_manifest_present "$fixture_manifest_present" \
        --argjson guest_telemetry_analyzer_exit_code \
            "$guest_telemetry_analyzer_exit_code" \
        --argjson observe_seconds "$observe_seconds" \
        --argjson paired_runs "$pair_count" \
        --argjson renderer_analyzer_exit_code "$renderer_analyzer_exit_code" \
        '{
            name: $name,
            paired_runs: $paired_runs,
            observe_seconds: $observe_seconds,
            fixture_manifest_present: $fixture_manifest_present,
            renderer_analyzer_exit_code: $renderer_analyzer_exit_code,
            guest_telemetry_analyzer_exit_code:
                $guest_telemetry_analyzer_exit_code
        }' >>"$RESULT_MANIFEST_LINES"
done

readonly SENSITIVE_MATCHES="$WORK_DIRECTORY/sensitive-matches.txt"
set +e
rg -l -i \
    "(^|[^[:alnum:]_])[\"']?((([[:alnum:]]+[_-])*(password|passwd|ticket|secret|authorization|credential|api[_-]?key|private[_-]?key)([_-][[:alnum:]]+)*)|(token([_-](value|secret|key))?)|(([[:alnum:]]+[_-])*(access|auth|bearer|refresh|session|spice|oauth|api|github|gitlab)[_-]token([_-][[:alnum:]]+)*))[\"']?[[:space:]]*[:=][[:space:]]*[^[:space:]]+" \
    "$ARCHIVE_ROOT" >"$SENSITIVE_MATCHES"
sensitive_scan_exit_code=$?
set -e
if ((sensitive_scan_exit_code == 0)); then
    echo "possible credential field found; refusing to archive these files:" >&2
    sed 's#^.*/swiftspice-benchmark-evidence/##' \
        "$SENSITIVE_MATCHES" >&2
    exit 1
fi
if ((sensitive_scan_exit_code != 1)); then
    echo "sensitive-field scan failed" >&2
    exit 1
fi

RESULT_SETS_JSON="$(jq -s '.' "$RESULT_MANIFEST_LINES")"
readonly RESULT_SETS_JSON
jq -n \
    --arg archive_tool_sha256 "$ARCHIVE_TOOL_SHA256" \
    --arg common_analyzer_blob "$COMMON_ANALYZER_BLOB" \
    --arg common_analyzer_sha256 "$COMMON_ANALYZER_SHA256" \
    --arg guest_telemetry_analyzer_sha256 \
        "$GUEST_TELEMETRY_ANALYZER_SHA256" \
    --arg renderer_analyzer_blob "$RENDERER_ANALYZER_BLOB" \
    --arg renderer_analyzer_sha256 "$RENDERER_ANALYZER_SHA256" \
    --arg renderer_runner_blob "$RENDERER_RUNNER_BLOB" \
    --arg renderer_runner_sha256 "$RENDERER_RUNNER_SHA256" \
    --arg tested_commit_time "$TESTED_COMMIT_TIME" \
    --arg tested_head "$TESTED_HEAD" \
    --argjson result_sets "$RESULT_SETS_JSON" \
    --argjson used_boot_epoch "$USED_BOOT_EPOCH_JSON" \
    --argjson used_hook "$USED_HOOK_JSON" \
    '{
        schema_version: 1,
        evidence_kind: "direct-renderer-pairs",
        tested_head: $tested_head,
        tested_commit_time: $tested_commit_time,
        tools: {
            common_analyzer: {
                archived_as: "tools/analyze.py",
                git_blob: $common_analyzer_blob,
                sha256: $common_analyzer_sha256
            },
            renderer_analyzer: {
                archived_as: "tools/analyze_renderer_pairs.py",
                git_blob: $renderer_analyzer_blob,
                sha256: $renderer_analyzer_sha256
            },
            renderer_runner: {
                archived_as: "tools/run_renderer_pairs.sh",
                git_blob: $renderer_runner_blob,
                sha256: $renderer_runner_sha256
            },
            guest_telemetry_analyzer: {
                archived_as: "tools/analyze_guest_telemetry.py",
                sha256: $guest_telemetry_analyzer_sha256
            },
            archive_tool: {
                archived_as: "tools/archive_renderer_results.sh",
                sha256: $archive_tool_sha256
            },
            used_hook: $used_hook,
            used_boot_epoch: $used_boot_epoch
        },
        result_sets: $result_sets,
        contents: [
            "pair-??-{cpu-iosurface,metal}.json",
            "pair-??-{cpu-iosurface,metal}.meta.json",
            "pair-??-{cpu-iosurface,metal}.time.txt",
            "integrity-failures.tsv when present",
            "fixture-manifest.json when present",
            "remote-rounds/*-{server,guest-telemetry}.log",
            "remote-rounds/*-{configuration,versions}.txt",
            "renderer analyzer output and exit code",
            "guest telemetry analyzer output and exit code",
            "exact tested common/direct analyzers and renderer runner",
            "current guest telemetry analyzer and archive tool",
            "used hook and boot-epoch scripts when supplied"
        ]
    }' >"$ARCHIVE_ROOT/manifest.json"

(
    cd "$ARCHIVE_ROOT"
    find manifest.json results tools -type f -print \
        | LC_ALL=C sort \
        | while IFS= read -r file; do
            shasum -a 256 "$file"
        done >SHA256SUMS
    shasum -a 256 -c SHA256SUMS >/dev/null
)

readonly STAGED_ARCHIVE="$WORK_DIRECTORY/$OUTPUT_BASENAME"
readonly STAGED_TAR="$WORK_DIRECTORY/evidence.tar"
readonly ARCHIVE_PATHS="$WORK_DIRECTORY/archive-paths.txt"
find "$ARCHIVE_ROOT" -exec touch -t 200001010000.00 {} +
(
    cd "$WORK_DIRECTORY"
    find swiftspice-benchmark-evidence -print \
        | LC_ALL=C sort >"$ARCHIVE_PATHS"
    COPYFILE_DISABLE=1 tar -cf "$STAGED_TAR" \
        --format ustar --uid 0 --gid 0 --uname root --gname wheel \
        --no-acls --no-fflags --no-mac-metadata --no-xattrs \
        --no-recursion -T "$ARCHIVE_PATHS"
)
gzip -n -c "$STAGED_TAR" >"$STAGED_ARCHIVE"
if [[ -e "$OUTPUT_PATH" || -L "$OUTPUT_PATH" ]]; then
    echo "output appeared while the archive was being built: $OUTPUT_PATH" >&2
    exit 2
fi
mv -n "$STAGED_ARCHIVE" "$OUTPUT_PATH"
if [[ -e "$STAGED_ARCHIVE" || -L "$STAGED_ARCHIVE" ]]; then
    echo "refused to replace output that appeared concurrently: $OUTPUT_PATH" >&2
    exit 2
fi
printf 'archive=%s\n' "$OUTPUT_PATH"
printf 'sha256=%s\n' "$(sha256_of "$OUTPUT_PATH")"
