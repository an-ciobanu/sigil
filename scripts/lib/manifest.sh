#!/usr/bin/env bash
# Sigil manifest CRUD: read and mutate ~/.sigil/manifest.json.
#
# Concurrency: this library does NOT take the lock. Callers performing
# compound operations (e.g., /sigil:add does fetch + scan + manifest add +
# install) should acquire the lock once via scripts/lib/lock.sh before
# calling these functions, and release at the end.
#
# All write operations use atomic rename (jq → tmp → mv) so a crashed or
# signalled process leaves either the old manifest or the new one — never
# a partial write.
#
# ── Manifest schema (version 1) ─────────────────────────────────────────
# {
#   "version": 1,
#   "sources": [<entry>, ...]
# }
#
# Entry fields:
#   name          (string, required)  — fs-safe identifier; matches
#                                       [a-zA-Z0-9._-]+ ; uniquely keys
#                                       this entry within the manifest.
#   kind          (string, required)  — one of:
#                                         "claude-plugin" — Claude Code
#                                            plugin; install = file copy
#                                            into ~/.claude/plugins/.
#                                         "rust-cargo" — Rust binary;
#                                            install = `cargo build
#                                            --release` then copy.
#                                         "untracked" — pre-existing
#                                            plugin adopted via
#                                            /sigil:adopt; scan-only,
#                                            cannot be updated by Sigil.
#   install_path  (string, required)  — absolute path where the component
#                                       lives on disk after install.
#   installed_at  (string, required)  — ISO-8601 UTC timestamp of the
#                                       last successful install or update.
#   source        (string, required for claude-plugin / rust-cargo)
#                                     — git URL the entry was installed
#                                       from. Omitted for untracked.
#   current_sha   (string, required for claude-plugin / rust-cargo)
#                                     — 40-char lowercase hex git commit
#                                       SHA the user approved.
#   branch        (string, optional)  — non-default ref the source was
#                                       cloned from (`--branch` on add).
#                                       Re-used by /sigil:update so the
#                                       same ref is followed for updates.
#   path          (string, optional)  — subdirectory of the cloned repo
#                                       that was installed (`--path` on
#                                       add). Re-used by /sigil:update.
#   notes         (string, optional)  — free-form note from /sigil:add.
# ────────────────────────────────────────────────────────────────────────

_MANIFEST_LIB_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=state.sh
source "${_MANIFEST_LIB_DIR}/state.sh"

SIGIL_MANIFEST_SCHEMA_VERSION=1

# Internal: ensure jq is available. Returns 0 if usable, 1 with stderr.
_sigil_manifest_require_jq() {
    if ! command -v jq &> /dev/null; then
        echo "ERROR: jq is required to manipulate the Sigil manifest." >&2
        echo "       Install via Homebrew (\`brew install jq\`) or your" >&2
        echo "       system package manager." >&2
        return 1
    fi
}

# Internal: confirm manifest version matches what this library understands.
_sigil_manifest_check_version() {
    local v
    v="$(jq -r '.version // empty' "${SIGIL_MANIFEST_PATH}" 2>/dev/null || true)"
    if [[ "${v}" != "${SIGIL_MANIFEST_SCHEMA_VERSION}" ]]; then
        echo "ERROR: unsupported manifest schema version '${v:-<missing>}' at ${SIGIL_MANIFEST_PATH}" >&2
        echo "       Expected version ${SIGIL_MANIFEST_SCHEMA_VERSION}." >&2
        return 1
    fi
}

# Atomic write: jq filter > tmp > rename. Args:
#   $1   — jq filter
#   $@   — additional jq args (e.g., --arg, --argjson)
_sigil_manifest_apply() {
    local filter="$1"
    shift
    local tmp="${SIGIL_MANIFEST_PATH}.tmp.$$"
    if ! jq "$@" "${filter}" "${SIGIL_MANIFEST_PATH}" > "${tmp}"; then
        rm -f "${tmp}"
        return 1
    fi
    mv "${tmp}" "${SIGIL_MANIFEST_PATH}"
}

# Validate an entry JSON string. Returns 0 if valid, 1 with stderr.
sigil_manifest_validate_entry() {
    _sigil_manifest_require_jq || return 1
    local entry="$1"
    if ! jq -e . <<<"${entry}" > /dev/null 2>&1; then
        echo "ERROR: manifest entry is not valid JSON" >&2
        return 1
    fi

    local name kind install_path installed_at source current_sha
    name="$(jq -r '.name // empty' <<<"${entry}")"
    if [[ -z "${name}" ]]; then
        echo "ERROR: manifest entry missing required field: name" >&2
        return 1
    fi
    if ! [[ "${name}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        echo "ERROR: invalid name '${name}' (allowed: letters, digits, '.', '_', '-')" >&2
        return 1
    fi

    kind="$(jq -r '.kind // empty' <<<"${entry}")"
    case "${kind}" in
        claude-plugin|rust-cargo|untracked) ;;
        "")
            echo "ERROR: manifest entry missing required field: kind" >&2
            return 1
            ;;
        *)
            echo "ERROR: invalid kind '${kind}' (allowed: claude-plugin, rust-cargo, untracked)" >&2
            return 1
            ;;
    esac

    install_path="$(jq -r '.install_path // empty' <<<"${entry}")"
    if [[ -z "${install_path}" ]]; then
        echo "ERROR: manifest entry missing required field: install_path" >&2
        return 1
    fi

    installed_at="$(jq -r '.installed_at // empty' <<<"${entry}")"
    if [[ -z "${installed_at}" ]]; then
        echo "ERROR: manifest entry missing required field: installed_at" >&2
        return 1
    fi

    if [[ "${kind}" != "untracked" ]]; then
        source="$(jq -r '.source // empty' <<<"${entry}")"
        if [[ -z "${source}" ]]; then
            echo "ERROR: manifest entry of kind '${kind}' missing required field: source" >&2
            return 1
        fi
        current_sha="$(jq -r '.current_sha // empty' <<<"${entry}")"
        if ! [[ "${current_sha}" =~ ^[0-9a-f]{40}$ ]]; then
            echo "ERROR: invalid current_sha for kind '${kind}' (must be 40 lowercase hex chars; got '${current_sha}')" >&2
            return 1
        fi
    fi
    return 0
}

# List names of all tracked sources, one per line.
sigil_manifest_list_names() {
    _sigil_manifest_require_jq || return 1
    sigil_init_manifest_if_missing
    _sigil_manifest_check_version || return 1
    jq -r '.sources[].name' "${SIGIL_MANIFEST_PATH}"
}

# Number of tracked sources.
sigil_manifest_count() {
    _sigil_manifest_require_jq || return 1
    sigil_init_manifest_if_missing
    _sigil_manifest_check_version || return 1
    jq -r '.sources | length' "${SIGIL_MANIFEST_PATH}"
}

# Returns 0 if an entry exists with the given name, 1 otherwise.
sigil_manifest_has() {
    _sigil_manifest_require_jq || return 1
    sigil_init_manifest_if_missing
    _sigil_manifest_check_version || return 1
    local name="$1"
    jq -e --arg n "${name}" '.sources[] | select(.name == $n)' "${SIGIL_MANIFEST_PATH}" > /dev/null 2>&1
}

# Print the entry with the given name as JSON. Returns 1 if not found.
sigil_manifest_get() {
    _sigil_manifest_require_jq || return 1
    sigil_init_manifest_if_missing
    _sigil_manifest_check_version || return 1
    local name="$1"
    jq -e --arg n "${name}" '.sources[] | select(.name == $n)' "${SIGIL_MANIFEST_PATH}"
}

# Add an entry. Errors if an entry with the same name already exists or if
# the entry fails validation.
sigil_manifest_add() {
    _sigil_manifest_require_jq || return 1
    sigil_init_manifest_if_missing
    _sigil_manifest_check_version || return 1

    local entry="$1"
    sigil_manifest_validate_entry "${entry}" || return 1

    local name
    name="$(jq -r '.name' <<<"${entry}")"
    if sigil_manifest_has "${name}"; then
        echo "ERROR: manifest already contains an entry named '${name}'" >&2
        return 1
    fi

    _sigil_manifest_apply '.sources += [$e]' --argjson e "${entry}"
}

# Replace the entry with the given name. Errors if the entry doesn't exist
# or if the new entry fails validation. Note: the new entry's name must
# match the lookup name (we don't permit renaming via update).
sigil_manifest_update() {
    _sigil_manifest_require_jq || return 1
    sigil_init_manifest_if_missing
    _sigil_manifest_check_version || return 1

    local name="$1"
    local entry="$2"

    sigil_manifest_validate_entry "${entry}" || return 1

    local entry_name
    entry_name="$(jq -r '.name' <<<"${entry}")"
    if [[ "${entry_name}" != "${name}" ]]; then
        echo "ERROR: update would rename '${name}' -> '${entry_name}'; use remove + add instead" >&2
        return 1
    fi

    if ! sigil_manifest_has "${name}"; then
        echo "ERROR: no manifest entry named '${name}'" >&2
        return 1
    fi

    _sigil_manifest_apply \
        '.sources |= map(if .name == $n then $e else . end)' \
        --arg n "${name}" --argjson e "${entry}"
}

# Remove the entry with the given name. Returns 0 even if the entry was
# already absent (idempotent), but prints a note to stderr in that case.
sigil_manifest_remove() {
    _sigil_manifest_require_jq || return 1
    sigil_init_manifest_if_missing
    _sigil_manifest_check_version || return 1

    local name="$1"
    if ! sigil_manifest_has "${name}"; then
        echo "Note: no manifest entry named '${name}' to remove" >&2
        return 0
    fi

    _sigil_manifest_apply '.sources |= map(select(.name != $n))' --arg n "${name}"
}
