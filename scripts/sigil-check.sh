#!/usr/bin/env bash
# /sigil:check entrypoint — clone a source to staging and scan with vexscan.
# This is the deterministic half of the check flow; the slash-command
# markdown layers a Claude subagent review on top to produce the verdict.
#
# Usage: sigil-check.sh <git-url>
#
# No manifest write happens here, so no lock is acquired. Each run uses
# a unique staging dir (mktemp under SIGIL_STAGING_DIR), so concurrent
# checks don't collide.
#
# Staging dirs are NOT cleaned up automatically. They accumulate under
# ~/.sigil/staging/check-* until removed manually or by a future
# /sigil:cleanup command.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=lib/state.sh
source "${SCRIPT_DIR}/lib/state.sh"
# shellcheck source=lib/vexscan/lib.sh
source "${SCRIPT_DIR}/lib/vexscan/lib.sh"

usage() {
    cat <<EOF
Usage: sigil-check.sh <git-url> [--branch <ref>] [--path <subpath>]

Clones the source to ~/.sigil/staging/check-XXX/repo and runs vexscan
against it. Prints labeled output for the slash command to feed into
a Claude subagent for verdict generation.

  --branch <ref>     Clone a non-default branch, tag, or commit SHA.
                     Tries shallow clone (-b) first; falls back to a
                     full clone with checkout if the ref is a SHA.
  --path <subpath>   Scan only a subdirectory of the clone (e.g.
                     for a monorepo plugin). The path is validated
                     to stay within the clone.
EOF
}

if ! command -v jq &> /dev/null; then
    echo "ERROR: jq is required for /sigil:check" >&2
    exit 1
fi
if ! command -v git &> /dev/null; then
    echo "ERROR: git is required for /sigil:check" >&2
    exit 1
fi

URL=""
BRANCH=""
SUBPATH=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            usage
            exit 0
            ;;
        --branch)
            shift
            if [[ $# -eq 0 ]]; then
                echo "ERROR: --branch requires a value" >&2
                exit 1
            fi
            BRANCH="$1"
            ;;
        --path)
            shift
            if [[ $# -eq 0 ]]; then
                echo "ERROR: --path requires a value" >&2
                exit 1
            fi
            SUBPATH="$1"
            ;;
        --*)
            echo "ERROR: unknown flag: $1" >&2
            usage >&2
            exit 1
            ;;
        *)
            if [[ -z "${URL}" ]]; then
                URL="$1"
            else
                echo "ERROR: too many positional arguments" >&2
                usage >&2
                exit 1
            fi
            ;;
    esac
    shift
done

if [[ -z "${URL}" ]]; then
    echo "ERROR: git URL is required" >&2
    usage >&2
    exit 1
fi

# Loose URL validation — accept the common git-clone-able forms.
# file:// is allowed for local fixtures and manually-downloaded sources.
case "${URL}" in
    https://*|http://*|git://*|git@*|ssh://*|file://*) ;;
    *)
        echo "ERROR: not a git URL: ${URL}" >&2
        echo "       Expected one of: https://..., http://..., git://..., git@host:..., ssh://..., file://..." >&2
        exit 1
        ;;
esac

sigil_vexscan_require_installed || exit 1
sigil_ensure_state_dir

STAGE_ROOT="$(mktemp -d "${SIGIL_STAGING_DIR}/check-XXXXXX")"
CLONE_DIR="${STAGE_ROOT}/repo"
SCAN_JSON="${STAGE_ROOT}/scan.json"

echo "Cloning ${URL}..." >&2
if [[ -n "${BRANCH}" ]]; then
    # Try shallow clone with -b first (works for branches and tags). If
    # that fails (e.g., the ref is an arbitrary SHA), fall back to a
    # full clone and checkout the ref.
    if ! git clone --quiet --depth 1 -b "${BRANCH}" "${URL}" "${CLONE_DIR}" 2>/dev/null; then
        if ! git clone --quiet "${URL}" "${CLONE_DIR}" 2>/dev/null; then
            rm -rf "${STAGE_ROOT}"
            echo "ERROR: failed to clone ${URL}" >&2
            exit 1
        fi
        if ! git -C "${CLONE_DIR}" checkout --quiet "${BRANCH}" 2>/dev/null; then
            rm -rf "${STAGE_ROOT}"
            echo "ERROR: failed to checkout '${BRANCH}' in ${URL}" >&2
            exit 1
        fi
    fi
else
    # Shallow clone of the default branch — we just want the tip for scanning.
    if ! git clone --quiet --depth 1 "${URL}" "${CLONE_DIR}" 2>&1; then
        rm -rf "${STAGE_ROOT}"
        echo "ERROR: failed to clone ${URL}" >&2
        exit 1
    fi
fi

COMMIT="$(git -C "${CLONE_DIR}" rev-parse HEAD)"

# Resolve --path to an absolute, physically-canonical path. `pwd -P`
# resolves symlinks to their physical target, so a malicious repo
# containing a symlink at the --path target (e.g., `plugin -> /etc`)
# can't escape the clone — we'd resolve to /etc and the under-clone
# check would reject it.
if [[ -n "${SUBPATH}" ]]; then
    if [[ "${SUBPATH}" == /* ]]; then
        rm -rf "${STAGE_ROOT}"
        echo "ERROR: --path must be a relative subpath, not an absolute path" >&2
        exit 1
    fi
    REPO_DIR="$(cd "${CLONE_DIR}/${SUBPATH}" 2>/dev/null && pwd -P)" || {
        rm -rf "${STAGE_ROOT}"
        echo "ERROR: --path '${SUBPATH}' does not exist or is not a directory in the clone" >&2
        exit 1
    }
    ABS_CLONE="$(cd "${CLONE_DIR}" && pwd -P)"
    if [[ "${REPO_DIR}" != "${ABS_CLONE}" && "${REPO_DIR}" != "${ABS_CLONE}/"* ]]; then
        rm -rf "${STAGE_ROOT}"
        echo "ERROR: --path '${SUBPATH}' escapes the clone directory (possibly via symlink)" >&2
        exit 1
    fi
else
    REPO_DIR="${CLONE_DIR}"
fi

echo "Scanning with vexscan..." >&2
# --ast: catch obfuscation. --deps: supply-chain checks. --skip-deps:
# don't scan inside node_modules (avoid vendored-code noise).
if ! sigil_vexscan_run scan "${REPO_DIR}" \
        --ast --deps --skip-deps \
        -f json > "${SCAN_JSON}" 2>/dev/null; then
    # vexscan returns non-zero when findings exist at fail-on threshold;
    # that's a successful scan with results, not a tooling error. Only
    # treat truly empty output as a failure.
    if [[ ! -s "${SCAN_JSON}" ]]; then
        echo "ERROR: vexscan produced no output" >&2
        exit 1
    fi
fi

# Validate that we got well-formed JSON. A truncated/corrupted scan.json
# (vexscan crash mid-write) would otherwise cascade into garbled summary
# counts and a confusing subagent prompt.
if ! jq empty "${SCAN_JSON}" 2>/dev/null; then
    echo "ERROR: vexscan output is not valid JSON (scan.json corrupt)" >&2
    exit 1
fi

# Summarize severity counts for the human-readable header.
# `// 0` defaults guard against an unexpected schema (e.g., empty results).
read -r CRITICAL HIGH MEDIUM LOW INFO <<< "$(jq -r '
    [(.results // [])[].findings[]?.severity] as $s |
    [
      (($s | map(select(. == "critical")) | length) // 0),
      (($s | map(select(. == "high"))     | length) // 0),
      (($s | map(select(. == "medium"))   | length) // 0),
      (($s | map(select(. == "low"))      | length) // 0),
      (($s | map(select(. == "info"))     | length) // 0)
    ] | @tsv
' "${SCAN_JSON}")"

{
    echo "=== Sigil check ==="
    echo "URL:        ${URL}"
    [[ -n "${BRANCH}" ]] && echo "Branch:     ${BRANCH}"
    [[ -n "${SUBPATH}" ]] && echo "Path:       ${SUBPATH}"
    echo "Commit:     ${COMMIT}"
    echo "Stage root: ${STAGE_ROOT}"
    echo "Repo:       ${REPO_DIR}"
    echo "Scan:       ${SCAN_JSON}"
    echo "Summary:    ${CRITICAL} critical, ${HIGH} high, ${MEDIUM} medium, ${LOW} low, ${INFO} info"
    echo ""
    echo "=== Vexscan findings (JSON) ==="
}
cat "${SCAN_JSON}"
