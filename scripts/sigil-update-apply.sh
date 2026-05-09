#!/usr/bin/env bash
# /sigil:update apply step — atomically replace a tracked claude-plugin's
# install_path with a vetted, staged copy and bump current_sha +
# installed_at in the manifest. Called by /sigil:update's markdown AFTER
# the verdict subagent has run and gating has passed.
#
# Usage:
#   sigil-update-apply.sh --name <name> --new-sha <40-hex> --repo <staged-repo>
#
# All other manifest fields (source, kind, install_path, branch, path,
# notes) are read from the existing entry and preserved.
#
# Atomicity: stages the new copy at <install_path>.new.<pid>, moves the
# old aside to <install_path>.old.<pid>, swaps in the new, updates the
# manifest, then removes the backup. On any failure during the swap or
# manifest write we restore the old install_path from the backup.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=lib/manifest.sh
source "${SCRIPT_DIR}/lib/manifest.sh"
# shellcheck source=lib/lock.sh
source "${SCRIPT_DIR}/lib/lock.sh"

usage() {
    cat <<EOF
Usage: sigil-update-apply.sh --name <name> --new-sha <40-hex> --repo <repo>

Replaces the install_path of the manifest entry named <name> with the
staged repo at <repo> and bumps current_sha + installed_at in the
manifest. Only kind=claude-plugin is supported in this story; other
kinds will error out cleanly.
EOF
}

if ! command -v jq &> /dev/null; then
    echo "ERROR: jq is required" >&2
    exit 1
fi

NAME=""
NEW_SHA=""
REPO=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)    shift; NAME="${1:-}" ;;
        --new-sha) shift; NEW_SHA="${1:-}" ;;
        --repo)    shift; REPO="${1:-}" ;;
        --help|-h) usage; exit 0 ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

for arg in NAME NEW_SHA REPO; do
    if [[ -z "${!arg:-}" ]]; then
        # downcase manually for bash 3.2 compatibility (no ${var,,})
        case "${arg}" in
            NAME)    flag="--name" ;;
            NEW_SHA) flag="--new-sha" ;;
            REPO)    flag="--repo" ;;
        esac
        echo "ERROR: ${flag} is required" >&2
        usage >&2
        exit 1
    fi
done

if ! [[ "${NEW_SHA}" =~ ^[0-9a-f]{40}$ ]]; then
    echo "ERROR: --new-sha must be a 40-char lowercase hex SHA (got '${NEW_SHA}')" >&2
    exit 1
fi

if [[ ! -d "${REPO}" ]]; then
    echo "ERROR: --repo path does not exist or is not a directory: ${REPO}" >&2
    exit 1
fi

# Path-safety guard (refuse install_path that's not strictly under $HOME).
# The manifest writer (/sigil:add) constructs install_path from a
# regex-validated NAME under $HOME, but a user could in principle hand-edit
# manifest.json. This re-validates at apply time.
_path_is_safe_to_delete() {
    local p="$1"
    if [[ "${p}" != /* ]]; then return 1; fi
    if [[ "${p}" != "${HOME}"/* ]]; then return 1; fi
    local under="${p#"${HOME}"/}"
    if [[ -z "${under}" || "${under}" == "${p}" ]]; then return 1; fi
    return 0
}

do_apply() {
    if ! sigil_manifest_has "${NAME}"; then
        echo "ERROR: no manifest entry named '${NAME}'" >&2
        echo "       Run /sigil:status to list known names." >&2
        return 1
    fi

    local existing kind install_path
    existing="$(sigil_manifest_get "${NAME}")"
    kind="$(jq -r '.kind' <<<"${existing}")"
    install_path="$(jq -r '.install_path' <<<"${existing}")"

    case "${kind}" in
        claude-plugin)
            ;;
        rust-cargo)
            echo "ERROR: kind 'rust-cargo' is not yet supported via /sigil:update." >&2
            echo "       General rust-cargo support is planned in a follow-up story." >&2
            return 1
            ;;
        untracked)
            echo "ERROR: kind 'untracked' has no source URL — cannot update." >&2
            return 1
            ;;
        *)
            echo "ERROR: unknown kind '${kind}' for entry '${NAME}'" >&2
            return 1
            ;;
    esac

    if ! _path_is_safe_to_delete "${install_path}"; then
        echo "ERROR: refusing to replace unsafe install_path: ${install_path}" >&2
        echo "       Path must be absolute and strictly under \$HOME (${HOME})." >&2
        return 1
    fi

    # Build the new manifest entry first so a schema problem fails before
    # we touch the filesystem.
    local installed_at new_entry
    installed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    new_entry="$(jq --arg sha "${NEW_SHA}" --arg ts "${installed_at}" \
        '.current_sha = $sha | .installed_at = $ts' <<<"${existing}")"
    if ! sigil_manifest_validate_entry "${new_entry}" > /dev/null; then
        echo "ERROR: refused to update — new manifest entry failed validation" >&2
        return 1
    fi

    # Stage the new copy alongside the existing install. cp -R preserves
    # the executable bit on hook scripts; .git is stripped post-copy.
    # Leading-dot names so Claude Code's plugin discovery doesn't pick up
    # the transient .new.<pid> / .old.<pid> siblings during the swap.
    local install_dir install_base
    install_dir="$(dirname "${install_path}")"
    install_base="$(basename "${install_path}")"
    local staging="${install_dir}/.${install_base}.new.$$"
    rm -rf "${staging}"
    if ! cp -R "${REPO}" "${staging}"; then
        rm -rf "${staging}"
        echo "ERROR: failed to copy staged repo to ${staging}" >&2
        return 1
    fi
    rm -rf "${staging}/.git"

    # Atomic-ish swap: move old aside, new into place. If the second mv
    # fails, restore the old install_path so the system isn't left empty.
    local backup="${install_dir}/.${install_base}.old.$$"
    rm -rf "${backup}"
    local had_old=0
    if [[ -e "${install_path}" ]]; then
        if ! mv "${install_path}" "${backup}"; then
            rm -rf "${staging}"
            echo "ERROR: failed to back up existing install_path" >&2
            return 1
        fi
        had_old=1
    fi

    if ! mv "${staging}" "${install_path}"; then
        # Restore the old install if we backed it up.
        if (( had_old )); then
            mv "${backup}" "${install_path}" || true
        fi
        rm -rf "${staging}"
        echo "ERROR: failed to install ${install_path}" >&2
        return 1
    fi

    # Manifest write last — it's the only step that's truly atomic
    # (jq -> tmp -> rename in lib/manifest.sh). If it fails, roll back
    # the filesystem from the backup so the manifest and on-disk state
    # stay in agreement.
    if ! sigil_manifest_update "${NAME}" "${new_entry}"; then
        rm -rf "${install_path}"
        if (( had_old )); then
            mv "${backup}" "${install_path}" || true
        fi
        echo "ERROR: manifest update failed; rolled back install_path" >&2
        return 1
    fi

    rm -rf "${backup}"

    local short_sha="${NEW_SHA:0:7}"
    echo "Updated '${NAME}' to ${short_sha}"
    echo "  Source:   $(jq -r .source <<<"${new_entry}")"
    echo "  New SHA:  ${NEW_SHA}"
    echo "  Path:     ${install_path}"
}

sigil_with_lock do_apply
