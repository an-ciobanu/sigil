#!/usr/bin/env bash
# Defensive cleanup helper. Removes a single staging directory after
# /sigil:check (or future /sigil:add) finishes. Verifies the target is
# strictly under SIGIL_STAGING_DIR before deleting, so a misfire by the
# slash-command markdown can't hit anything outside the staging area.
#
# Idempotent: silent success if the path is already gone.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=lib/state.sh
source "${SCRIPT_DIR}/lib/state.sh"

if [[ $# -ne 1 ]]; then
    echo "Usage: sigil-cleanup-stage.sh <stage-root-path>" >&2
    exit 1
fi

TARGET="$1"

# If the path is already gone, treat as no-op success.
if [[ ! -e "${TARGET}" ]]; then
    exit 0
fi

# Resolve to absolute via cd+pwd. cd into a non-dir would fail; we only
# delete directories.
ABS="$(cd "${TARGET}" 2>/dev/null && pwd)" || {
    echo "ERROR: not a directory: ${TARGET}" >&2
    exit 1
}

sigil_ensure_state_dir
STAGING_ABS="$(cd "${SIGIL_STAGING_DIR}" && pwd)"

# Refuse anything not strictly under the staging dir.
if [[ "${ABS}" != "${STAGING_ABS}/"* ]]; then
    echo "ERROR: refusing to delete path outside staging dir" >&2
    echo "       path:    ${ABS}" >&2
    echo "       staging: ${STAGING_ABS}" >&2
    exit 1
fi

# Refuse the staging dir itself.
relative="${ABS#"${STAGING_ABS}/"}"
if [[ -z "${relative}" || "${relative}" == "${ABS}" ]]; then
    echo "ERROR: refusing to delete the staging dir itself" >&2
    exit 1
fi

rm -rf "${ABS}"
