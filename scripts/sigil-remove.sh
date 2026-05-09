#!/usr/bin/env bash
# /sigil:remove entrypoint — uninstall a tracked source and remove it
# from the manifest in one step.
#
# Behavior depends on the entry's kind:
#   claude-plugin / rust-cargo  -> deletes install_path, then unregisters.
#   untracked                   -> only unregisters; does NOT delete files
#                                  (Sigil didn't install them, deletion
#                                  would be surprising).
#
# Safety: install_path must be under $HOME and strictly deeper than $HOME
# itself. Any other location is refused regardless of kind.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=lib/manifest.sh
source "${SCRIPT_DIR}/lib/manifest.sh"
# shellcheck source=lib/lock.sh
source "${SCRIPT_DIR}/lib/lock.sh"

usage() {
    cat <<EOF
Usage: sigil-remove.sh <name>

Removes the named source from the manifest. For tracked entries
(kind=claude-plugin or rust-cargo), the install_path is also deleted.
For kind=untracked, only the manifest entry is removed.
EOF
}

if ! command -v jq &> /dev/null; then
    echo "ERROR: jq is required for /sigil:remove" >&2
    exit 1
fi

NAME=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            usage
            exit 0
            ;;
        --*)
            echo "ERROR: unknown flag: $1" >&2
            usage >&2
            exit 1
            ;;
        *)
            if [[ -z "${NAME}" ]]; then
                NAME="$1"
            else
                echo "ERROR: too many positional arguments" >&2
                usage >&2
                exit 1
            fi
            ;;
    esac
    shift
done

if [[ -z "${NAME}" ]]; then
    echo "ERROR: name argument is required" >&2
    usage >&2
    exit 1
fi

# Reject install_paths that aren't safely under $HOME. This guards against
# a malformed/tampered manifest pointing at /, $HOME itself, or system
# directories. Sigil-installed paths are always under $HOME by construction.
_path_is_safe_to_delete() {
    local p="$1"
    if [[ "${p}" != /* ]]; then
        return 1
    fi
    if [[ "${p}" != "${HOME}"/* ]]; then
        return 1
    fi
    local under="${p#"${HOME}"/}"
    if [[ -z "${under}" || "${under}" == "${p}" ]]; then
        return 1
    fi
    return 0
}

do_remove() {
    if ! sigil_manifest_has "${NAME}"; then
        echo "ERROR: no manifest entry named '${NAME}'" >&2
        echo "       Run /sigil:status to list known names." >&2
        return 1
    fi

    local entry kind install_path
    entry="$(sigil_manifest_get "${NAME}")"
    kind="$(jq -r '.kind' <<<"${entry}")"
    install_path="$(jq -r '.install_path' <<<"${entry}")"

    case "${kind}" in
        claude-plugin|rust-cargo)
            if ! _path_is_safe_to_delete "${install_path}"; then
                echo "ERROR: refusing to delete unsafe install_path: ${install_path}" >&2
                echo "       Path must be absolute and strictly under \$HOME (${HOME})." >&2
                return 1
            fi
            if [[ -e "${install_path}" ]]; then
                rm -rf "${install_path}"
                echo "Deleted ${install_path}"
            else
                echo "Note: install_path already absent: ${install_path}"
            fi
            ;;
        untracked)
            echo "Note: kind=untracked — leaving files at ${install_path} untouched."
            ;;
        *)
            echo "ERROR: unknown kind '${kind}' for entry '${NAME}'" >&2
            return 1
            ;;
    esac

    sigil_manifest_remove "${NAME}" || return 1
    echo "Removed '${NAME}' from manifest."
}

sigil_with_lock do_remove
