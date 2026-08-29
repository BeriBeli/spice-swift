#!/bin/bash

set -euo pipefail

if [[ "$#" != 1 ]]; then
    echo "Usage: $0 RUN_DIR" >&2
    exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "${script_dir}/normalize-input-event.py" "$1"
