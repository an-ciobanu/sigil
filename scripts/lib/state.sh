#!/usr/bin/env bash
# Sigil state directory: paths and bootstrap helpers.
# Source from any script that touches ~/.sigil/ state.

# Override SIGIL_STATE_DIR for testing; defaults to ~/.sigil
SIGIL_STATE_DIR="${SIGIL_STATE_DIR:-$HOME/.sigil}"

SIGIL_MANIFEST_PATH="${SIGIL_STATE_DIR}/manifest.json"
SIGIL_LOCK_PATH="${SIGIL_STATE_DIR}/lock"
SIGIL_STAGING_DIR="${SIGIL_STATE_DIR}/staging"
SIGIL_VEXSCAN_DIR="${SIGIL_STATE_DIR}/vexscan"

# Schema version is bumped only on incompatible manifest changes.
SIGIL_MANIFEST_INITIAL='{
  "version": 1,
  "sources": []
}
'

sigil_ensure_state_dir() {
    mkdir -p "${SIGIL_STATE_DIR}" "${SIGIL_STAGING_DIR}" "${SIGIL_VEXSCAN_DIR}"
}

sigil_init_manifest_if_missing() {
    if [[ ! -f "${SIGIL_MANIFEST_PATH}" ]]; then
        printf '%s' "${SIGIL_MANIFEST_INITIAL}" > "${SIGIL_MANIFEST_PATH}"
    fi
}

sigil_bootstrap_state() {
    sigil_ensure_state_dir
    sigil_init_manifest_if_missing
}
