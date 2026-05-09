#!/usr/bin/env bash
# Bootstrap vexscan: clone at pinned commit, verify SHA, build, install.
# Idempotent — does nothing if the pinned binary is already present.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=lib/vexscan/lib.sh
source "${SCRIPT_DIR}/lib/vexscan/lib.sh"

if sigil_vexscan_is_installed; then
    echo "vexscan already installed at $(sigil_vexscan_binary_path)"
    exit 0
fi

sigil_vexscan_bootstrap
