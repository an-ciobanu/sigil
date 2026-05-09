#!/usr/bin/env bash
# Upstream-state checks for tracked sources via git ls-remote.

# Print the upstream HEAD sha (40-char lowercase hex) and return 0 on
# success. Print nothing and return 1 on failure (no git, network down,
# repo gone, malformed response).
sigil_upstream_get_head() {
    local url="$1"
    if ! command -v git &> /dev/null; then
        return 1
    fi
    local out
    if ! out="$(git ls-remote --quiet "${url}" HEAD 2>/dev/null)"; then
        return 1
    fi
    # ls-remote output: "<sha>\tHEAD"
    local sha
    sha="$(printf '%s' "${out}" | head -1 | awk '{print $1}')"
    if ! [[ "${sha}" =~ ^[0-9a-f]{40}$ ]]; then
        return 1
    fi
    printf '%s' "${sha}"
}

# Compare the current_sha to upstream HEAD. Always exits 0; the caller
# routes on the printed status word(s):
#   "uptodate"            — current_sha matches upstream HEAD
#   "behind <sha>"        — upstream HEAD differs from current_sha
#   "unreachable"         — couldn't resolve upstream HEAD
sigil_upstream_status() {
    local url="$1"
    local current_sha="$2"
    local upstream
    if ! upstream="$(sigil_upstream_get_head "${url}")"; then
        printf 'unreachable'
        return 0
    fi
    if [[ "${upstream}" == "${current_sha}" ]]; then
        printf 'uptodate'
    else
        printf 'behind %s' "${upstream}"
    fi
}
