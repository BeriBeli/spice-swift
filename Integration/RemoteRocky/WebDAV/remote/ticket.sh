#!/bin/bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_running
cat "${WEBDAV_STATE}/ticket"
printf '\n'
