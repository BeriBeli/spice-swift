#!/bin/bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

enter_lifecycle_lock "$@"
stop_endpoint_locked
echo "Performance endpoint stopped; the temporary ticket was removed."
