#!/usr/bin/env bash
# /sigil:add install step — copy a vetted, staged source into its
# install_path and add a manifest entry. Called by the /sigil:add markdown
# AFTER the verdict subagent has run and gating has passed.
#
# Usage:
#   sigil-add-install.sh \
#     --url    <git-url>                (required)
#     --commit <40-char SHA>            (required)
#     --name   <fs-safe name>           (required)
#     --kind   <claude-plugin>          (required; only kind supported in v1)
#     --repo   <staged repo path>       (required)
#
# Path under the lock for atomicity with the manifest.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=lib/manifest.sh
source "${SCRIPT_DIR}/lib/manifest.sh"
# shellcheck source=lib/lock.sh
source "${SCRIPT_DIR}/lib/lock.sh"

usage() {
    cat <<EOF
Usage: sigil-add-install.sh \\
         --url <git-url> --commit <sha> --name <name> --kind <kind> --repo <repo-path>

Only kind=claude-plugin is supported in this story (SIGIL-3.3).
EOF
}

if ! command -v jq &> /dev/null; then
    echo "ERROR: jq is required" >&2
    exit 1
fi

URL=""
COMMIT=""
NAME=""
KIND=""
REPO=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --url)    shift; URL="${1:-}" ;;
        --commit) shift; COMMIT="${1:-}" ;;
        --name)   shift; NAME="${1:-}" ;;
        --kind)   shift; KIND="${1:-}" ;;
        --repo)   shift; REPO="${1:-}" ;;
        --help|-h) usage; exit 0 ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

for arg in URL COMMIT NAME KIND REPO; do
    if [[ -z "${!arg:-}" ]]; then
        echo "ERROR: --${arg,,} is required" >&2
        usage >&2
        exit 1
    fi
done

# Validate NAME *before* any filesystem touch. Matches the regex used by
# the manifest validator (lib/manifest.sh sigil_manifest_validate_entry).
# A malformed name passing through cp / rm-rf is closed off here even
# though the manifest layer would reject it later.
if ! [[ "${NAME}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "ERROR: invalid --name '${NAME}' (allowed: letters, digits, '.', '_', '-')" >&2
    exit 1
fi

if ! [[ "${COMMIT}" =~ ^[0-9a-f]{40}$ ]]; then
    echo "ERROR: --commit must be a 40-char lowercase hex SHA (got '${COMMIT}')" >&2
    exit 1
fi

if [[ ! -d "${REPO}" ]]; then
    echo "ERROR: --repo path does not exist or is not a directory: ${REPO}" >&2
    exit 1
fi

INSTALL_PATH=""
case "${KIND}" in
    claude-plugin)
        INSTALL_PATH="${HOME}/.claude/plugins/${NAME}"
        ;;
    rust-cargo)
        echo "ERROR: kind 'rust-cargo' is not yet supported via /sigil:add." >&2
        echo "       vexscan itself uses scripts/sigil-bootstrap-vexscan.sh." >&2
        echo "       General rust-cargo support is planned in a follow-up story." >&2
        exit 1
        ;;
    untracked)
        echo "ERROR: kind 'untracked' is not supported by /sigil:add." >&2
        echo "       Use /sigil:adopt to register a pre-existing directory." >&2
        exit 1
        ;;
    *)
        echo "ERROR: unknown kind '${KIND}'" >&2
        exit 1
        ;;
esac

do_install() {
    if sigil_manifest_has "${NAME}"; then
        echo "ERROR: manifest already has an entry named '${NAME}'" >&2
        echo "       Choose a different --name or remove the existing entry first" >&2
        echo "       with /sigil:remove ${NAME}." >&2
        return 1
    fi

    if [[ -e "${INSTALL_PATH}" ]]; then
        echo "ERROR: install path already exists: ${INSTALL_PATH}" >&2
        echo "       Refusing to clobber. Remove it first if you really want" >&2
        echo "       to overwrite." >&2
        return 1
    fi

    mkdir -p "$(dirname "${INSTALL_PATH}")"

    # Copy the repo to the install path. cp -R preserves the executable
    # bit on hook scripts and other +x files. We strip .git afterward;
    # /sigil:update re-clones fresh, so the .git in the install path
    # would only be bulk and a leak source.
    cp -R "${REPO}" "${INSTALL_PATH}"
    rm -rf "${INSTALL_PATH}/.git"

    local installed_at entry
    installed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    entry="$(jq -n \
        --arg name   "${NAME}" \
        --arg kind   "${KIND}" \
        --arg src    "${URL}" \
        --arg sha    "${COMMIT}" \
        --arg path   "${INSTALL_PATH}" \
        --arg ts     "${installed_at}" \
        '{name:$name, kind:$kind, source:$src, current_sha:$sha, install_path:$path, installed_at:$ts}')"

    if ! sigil_manifest_add "${entry}"; then
        # Roll back the filesystem so we don't end up half-installed.
        rm -rf "${INSTALL_PATH}"
        return 1
    fi

    echo "Installed '${NAME}' (kind=${KIND})"
    echo "  Source:  ${URL}"
    echo "  Commit:  ${COMMIT}"
    echo "  Path:    ${INSTALL_PATH}"
    echo "  Run /sigil:status to see all tracked sources."
}

sigil_with_lock do_install
