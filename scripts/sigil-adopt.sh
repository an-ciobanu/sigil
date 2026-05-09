#!/usr/bin/env bash
# /sigil:adopt entrypoint — register an existing plugin directory in the
# Sigil manifest as kind=untracked. SessionStart will include it in scans,
# but Sigil cannot update it (no source URL).
#
# Usage: sigil-adopt.sh <path> [--name <name>]

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=lib/manifest.sh
source "${SCRIPT_DIR}/lib/manifest.sh"
# shellcheck source=lib/lock.sh
source "${SCRIPT_DIR}/lib/lock.sh"

usage() {
    cat <<EOF
Usage: sigil-adopt.sh <path> [--name <name>]

  <path>          Path to the existing plugin directory.
  --name <name>   Override the manifest name (default: basename of <path>).
EOF
}

if ! command -v jq &> /dev/null; then
    echo "ERROR: jq is required for /sigil:adopt" >&2
    exit 1
fi

PATH_ARG=""
NAME_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)
            shift
            if [[ $# -eq 0 ]]; then
                echo "ERROR: --name requires a value" >&2
                exit 1
            fi
            NAME_OVERRIDE="$1"
            ;;
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
            if [[ -z "${PATH_ARG}" ]]; then
                PATH_ARG="$1"
            else
                echo "ERROR: too many positional arguments" >&2
                usage >&2
                exit 1
            fi
            ;;
    esac
    shift
done

if [[ -z "${PATH_ARG}" ]]; then
    echo "ERROR: path argument is required" >&2
    usage >&2
    exit 1
fi

# Resolve to an absolute, canonical path so the manifest entry is stable
# across cwd changes.
ABS_PATH="$(cd "${PATH_ARG}" 2>/dev/null && pwd)" || {
    echo "ERROR: path does not exist or is not a directory: ${PATH_ARG}" >&2
    exit 1
}
if [[ ! -d "${ABS_PATH}" ]]; then
    echo "ERROR: not a directory: ${ABS_PATH}" >&2
    exit 1
fi

NAME="${NAME_OVERRIDE:-$(basename "${ABS_PATH}")}"

do_adopt() {
    if sigil_manifest_has "${NAME}"; then
        echo "ERROR: manifest already has an entry named '${NAME}'" >&2
        echo "       Use --name to choose a different name, or remove the existing" >&2
        echo "       entry first with /sigil:remove ${NAME}." >&2
        return 1
    fi

    local installed_at entry
    installed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    entry="$(jq -n \
        --arg name "${NAME}" \
        --arg path "${ABS_PATH}" \
        --arg ts "${installed_at}" \
        '{name: $name, kind: "untracked", install_path: $path, installed_at: $ts}')"

    sigil_manifest_add "${entry}" || return 1

    echo "Adopted '${NAME}' as kind=untracked (scan-only)."
    echo "  Path: ${ABS_PATH}"
    echo "  Run /sigil:status to see all tracked sources."
}

sigil_with_lock do_adopt
