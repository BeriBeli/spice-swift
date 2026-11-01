#!/usr/bin/env bash
# Shipped spice-gtk C artifact acceptance against independent upstream sources.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
[[ "$#" -eq 0 ]] || { echo "usage: validate-quic.sh" >&2; exit 2; }
./Scripts/verify-native-closure.sh --artifacts-only
python3 -B Tests/CSpiceQUICTests/validate.py --sanitize
