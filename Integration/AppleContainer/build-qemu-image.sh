#!/bin/bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly IMAGE_NAME="${SWIFTSPICE_QEMU_IMAGE:-swiftspice-qemu:local}"

container build \
    --tag "${IMAGE_NAME}" \
    --file "${SCRIPT_DIR}/Containerfile" \
    "${SCRIPT_DIR}"

echo "Built ${IMAGE_NAME}"
