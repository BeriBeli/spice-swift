#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
    echo "usage: $0 OUTPUT.tar.gz TESTED_GIT_REF RESULT_DIRECTORY [...]" >&2
    exit 2
fi

readonly OUTPUT="$1"
readonly TESTED_REF="$2"
shift 2

if [[ -e "$OUTPUT" ]]; then
    echo "output already exists: $OUTPUT" >&2
    exit 2
fi

ROOT_DIRECTORY="$(git rev-parse --show-toplevel)"
readonly ROOT_DIRECTORY
TESTED_HEAD="$(git -C "$ROOT_DIRECTORY" rev-parse "$TESTED_REF^{commit}")"
readonly TESTED_HEAD
TESTED_COMMIT_TIME="$(git -C "$ROOT_DIRECTORY" show -s --format=%cI "$TESTED_HEAD")"
readonly TESTED_COMMIT_TIME
ANALYZER_BLOB="$(git -C "$ROOT_DIRECTORY" rev-parse \
    "$TESTED_HEAD:Benchmarks/analyze.py")"
readonly ANALYZER_BLOB
LIVE_RUNNER_BLOB="$(git -C "$ROOT_DIRECTORY" rev-parse \
    "$TESTED_HEAD:Benchmarks/run_live_pairs.sh")"
readonly LIVE_RUNNER_BLOB
ARCHIVE_TOOL_SHA256="$(shasum -a 256 "$ROOT_DIRECTORY/Benchmarks/archive_results.sh" \
    | awk '{print $1}')"
readonly ARCHIVE_TOOL_SHA256

OUTPUT_PARENT="$(cd "$(dirname "$OUTPUT")" && pwd)"
readonly OUTPUT_PARENT
OUTPUT_PATH="$OUTPUT_PARENT/$(basename "$OUTPUT")"
readonly OUTPUT_PATH
WORK_DIRECTORY="$(mktemp -d "${TMPDIR:-/private/tmp}/swiftspice-evidence.XXXXXX")"
readonly WORK_DIRECTORY
readonly ARCHIVE_ROOT="$WORK_DIRECTORY/swiftspice-benchmark-evidence"
trap 'rm -rf "$WORK_DIRECTORY"' EXIT

mkdir -p "$ARCHIVE_ROOT/results" "$ARCHIVE_ROOT/tools"
git -C "$ROOT_DIRECTORY" show "$TESTED_HEAD:Benchmarks/analyze.py" \
    >"$ARCHIVE_ROOT/tools/analyze.py"
git -C "$ROOT_DIRECTORY" show "$TESTED_HEAD:Benchmarks/run_live_pairs.sh" \
    >"$ARCHIVE_ROOT/tools/run_live_pairs.sh"
cp "$ROOT_DIRECTORY/Benchmarks/archive_results.sh" "$ARCHIVE_ROOT/tools/"
RESULT_NAMES=()
for result_directory in "$@"; do
    if [[ ! -d "$result_directory" ]]; then
        echo "result directory does not exist: $result_directory" >&2
        exit 2
    fi
    result_name="$(basename "$result_directory")"
    if [[ ! "$result_name" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "unsafe result directory name: $result_name" >&2
        exit 2
    fi
    destination="$ARCHIVE_ROOT/results/$result_name"
    mkdir -p "$destination"

    shopt -s nullglob
    sample_files=(
        "$result_directory"/run-??-swiftspice.json
        "$result_directory"/run-??-spice-client-glib2.json
        "$result_directory"/run-??-*.meta.json
        "$result_directory"/run-??-*.time.txt
    )
    shopt -u nullglob
    if ((${#sample_files[@]} == 0)); then
        echo "no benchmark sample files in: $result_directory" >&2
        exit 2
    fi
    cp "${sample_files[@]}" "$destination/"
    if [[ -f "$result_directory/integrity-failures.tsv" ]]; then
        cp "$result_directory/integrity-failures.tsv" "$destination/"
    fi
    set +e
    UV_CACHE_DIR="${UV_CACHE_DIR:-/private/tmp/swiftspice-archive-uv-cache}" \
        uv run "$ARCHIVE_ROOT/tools/analyze.py" "$result_directory" --json \
        >"$destination/analyzer-output.txt" 2>&1
    analyzer_exit_code=$?
    set -e
    printf '%d\n' "$analyzer_exit_code" >"$destination/analyzer-exit-code.txt"
    RESULT_NAMES+=("$result_name")
done

if command -v rg >/dev/null; then
    if rg -n -i '"(password|ticket|secret|token|authorization)"[[:space:]]*:' \
        "$ARCHIVE_ROOT/results"; then
        echo "possible credential field found; refusing to archive" >&2
        exit 1
    fi
fi

RESULT_SETS_JSON="$(printf '%s\n' "${RESULT_NAMES[@]}" \
    | jq -Rsc 'split("\n") | map(select(length > 0))')"
readonly RESULT_SETS_JSON
jq -n \
    --arg analyzer_blob "$ANALYZER_BLOB" \
    --arg archive_tool_sha256 "$ARCHIVE_TOOL_SHA256" \
    --arg live_runner_blob "$LIVE_RUNNER_BLOB" \
    --arg tested_commit_time "$TESTED_COMMIT_TIME" \
    --arg tested_head "$TESTED_HEAD" \
    --argjson result_sets "$RESULT_SETS_JSON" \
    '{
        schema_version: 1,
        tested_head: $tested_head,
        tested_commit_time: $tested_commit_time,
        analyzer_git_blob: $analyzer_blob,
        live_runner_git_blob: $live_runner_blob,
        archive_tool_sha256: $archive_tool_sha256,
        result_sets: $result_sets,
        contents: [
            "run-*.json",
            "run-*.meta.json",
            "run-*.time.txt",
            "integrity-failures.tsv when present",
            "analyzer-output.txt",
            "analyzer-exit-code.txt",
            "exact tested analyzer and live runner",
            "archive tool"
        ]
    }' >"$ARCHIVE_ROOT/manifest.json"

(
    cd "$ARCHIVE_ROOT"
    find results tools -type f -print | LC_ALL=C sort | while IFS= read -r file; do
        shasum -a 256 "$file"
    done >SHA256SUMS
)

tar -czf "$OUTPUT_PATH" -C "$WORK_DIRECTORY" swiftspice-benchmark-evidence
printf 'archive=%s\n' "$OUTPUT_PATH"
printf 'sha256=%s\n' "$(shasum -a 256 "$OUTPUT_PATH" | awk '{print $1}')"
