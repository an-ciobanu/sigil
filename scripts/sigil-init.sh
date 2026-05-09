#!/usr/bin/env bash
# Initialize Sigil state directory and manifest. Idempotent.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=lib/state.sh
source "${SCRIPT_DIR}/lib/state.sh"

sigil_bootstrap_state

echo "Sigil state initialized at ${SIGIL_STATE_DIR}"
echo "  manifest: ${SIGIL_MANIFEST_PATH}"
echo "  staging:  ${SIGIL_STAGING_DIR}"
echo "  vexscan:  ${SIGIL_VEXSCAN_DIR}"
