#!/usr/bin/env bash
# Run all tests with coverage and enforce a merged production-source line baseline.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SCRATCH_PATH="${SWIFTSPICE_COVERAGE_SCRATCH_PATH:-$ROOT_DIR/.build/coverage}"
MINIMUM_LINE_COVERAGE="${SWIFTSPICE_MIN_LINE_COVERAGE:-69.0}"
IGNORE_FILENAME_REGEX='/(Tests|Plugins)/|/GeneratedMessages\.swift$|/\.build/'

if [[ ! "$MINIMUM_LINE_COVERAGE" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf '[coverage] invalid minimum line coverage: %s\n' "$MINIMUM_LINE_COVERAGE" >&2
    exit 1
fi

printf '[coverage] running the complete instrumented test suite\n'
swift test --disable-sandbox \
    --scratch-path "$SCRATCH_PATH" \
    --enable-code-coverage \
    -Xswiftc -warnings-as-errors \
    -q

coverage_json="$(swift test --disable-sandbox \
    --scratch-path "$SCRATCH_PATH" \
    --show-codecov-path)"
codecov_directory="$(dirname "$coverage_json")"
products_directory="$(dirname "$codecov_directory")"
profile="$codecov_directory/default.profdata"

shopt -s nullglob
coverage_binaries=("$products_directory"/*.xctest/Contents/MacOS/*)
shopt -u nullglob
if [[ "${#coverage_binaries[@]}" -eq 0 || ! -f "$profile" ]]; then
    printf '[coverage] SwiftPM did not produce test binaries and a merged profile\n' >&2
    exit 1
fi

llvm_cov="$(xcrun -f llvm-cov)"
llvm_cov_arguments=(
    export
    "${coverage_binaries[0]}"
    -instr-profile "$profile"
    --ignore-filename-regex="$IGNORE_FILENAME_REGEX"
    --summary-only
)
for ((index = 1; index < ${#coverage_binaries[@]}; index++)); do
    llvm_cov_arguments+=(-object "${coverage_binaries[$index]}")
done

summary="$({ "$llvm_cov" "${llvm_cov_arguments[@]}"; } | jq -er '
    .data[0].totals
    | [.lines.percent, .functions.percent, .regions.percent]
    | @tsv
')"
IFS=$'\t' read -r line_coverage function_coverage region_coverage <<<"$summary"

printf '[coverage] lines %.2f%% · functions %.2f%% · regions %.2f%%\n' \
    "$line_coverage" "$function_coverage" "$region_coverage"
if ! awk -v actual="$line_coverage" -v minimum="$MINIMUM_LINE_COVERAGE" \
    'BEGIN { exit !(actual >= minimum) }'; then
    printf '[coverage] line coverage %.2f%% is below the %.2f%% baseline\n' \
        "$line_coverage" "$MINIMUM_LINE_COVERAGE" >&2
    exit 1
fi
printf '[coverage] line coverage baseline %.2f%% passed\n' "$MINIMUM_LINE_COVERAGE"
