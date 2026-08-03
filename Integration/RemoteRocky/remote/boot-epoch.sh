#!/bin/bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_running
script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
status_output="$("${script_directory}/control.sh" status)"
boot_epoch="$(printf '%s\n' "${status_output}" | awk '
    /^PERF_STATUS / {
        for (field = 1; field <= NF; field++) {
            if ($field ~ /^boot_epoch=/) {
                sub(/^boot_epoch=/, "", $field)
                sub(/\r$/, "", $field)
                value = $field
            }
        }
    }
    END { print value }
')"
if [[ -z "${boot_epoch}" || "${boot_epoch}" == unknown ]]; then
    echo "guest boot epoch was not reported" >&2
    exit 1
fi
printf '%s\n' "${boot_epoch}"
