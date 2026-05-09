#!/usr/bin/env bash
# Sigil config: read user-tunable settings from ~/.sigil/config.json.
#
# Config schema (version 1):
#   {
#     "version": 1,
#     "min_severity": "info" | "low" | "medium" | "high" | "critical"
#   }
#
# Behavior on missing or malformed config: silently fall back to defaults.
# This library is intended to be used from contexts where surfacing config
# errors would be wrong (SessionStart hook) or where the caller already
# has its own user-facing flag (sigil-scan.sh's --min-severity). A
# future /sigil:config command can surface validation issues explicitly.

_CONFIG_LIB_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=state.sh
source "${_CONFIG_LIB_DIR}/state.sh"

SIGIL_CONFIG_PATH="${SIGIL_STATE_DIR}/config.json"
SIGIL_CONFIG_SCHEMA_VERSION=1

# Returns one of: info, low, medium (default), high, critical.
# Silently falls back to "medium" if the config file is missing,
# malformed, on a different schema version, or holds an invalid value.
sigil_config_get_min_severity() {
    local default="medium"

    if [[ ! -f "${SIGIL_CONFIG_PATH}" ]]; then
        printf '%s' "${default}"
        return 0
    fi
    if ! command -v jq &> /dev/null; then
        printf '%s' "${default}"
        return 0
    fi
    if ! jq empty "${SIGIL_CONFIG_PATH}" 2>/dev/null; then
        printf '%s' "${default}"
        return 0
    fi

    local v
    v="$(jq -r '.version // empty' "${SIGIL_CONFIG_PATH}" 2>/dev/null || true)"
    if [[ "${v}" != "${SIGIL_CONFIG_SCHEMA_VERSION}" ]]; then
        printf '%s' "${default}"
        return 0
    fi

    local val
    val="$(jq -r '.min_severity // empty' "${SIGIL_CONFIG_PATH}" 2>/dev/null || true)"
    case "${val}" in
        info|low|medium|high|critical)
            printf '%s' "${val}"
            ;;
        *)
            printf '%s' "${default}"
            ;;
    esac
}
