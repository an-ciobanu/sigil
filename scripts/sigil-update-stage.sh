#!/usr/bin/env bash
# /sigil:update staging step — clone the upstream tip of a tracked
# source, compute a diff against the approved current_sha, run vexscan,
# and emit labeled output. The slash-command markdown (SIGIL-4.3+) layers
# a Claude subagent review on top of these artifacts to produce a
# verdict, and SIGIL-4.4 adds the install gate.
#
# Usage: sigil-update-stage.sh <name>
#
# No manifest write here — read-only against the manifest, so no lock.
# Each run uses a unique staging dir.
#
# Staging dirs are NOT auto-cleaned. Markdown layer runs
# scripts/sigil-cleanup-stage.sh against the printed Stage root after
# the verdict is delivered.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=lib/state.sh
source "${SCRIPT_DIR}/lib/state.sh"
# shellcheck source=lib/manifest.sh
source "${SCRIPT_DIR}/lib/manifest.sh"
# shellcheck source=lib/vexscan/lib.sh
source "${SCRIPT_DIR}/lib/vexscan/lib.sh"

usage() {
    cat <<EOF
Usage: sigil-update-stage.sh <name>

Looks up <name> in the manifest, clones the source (full history,
not shallow — needed to diff against the approved current_sha),
runs vexscan on the new state, computes a git diff between
current_sha and upstream HEAD (or branch tip if recorded), and emits
labeled output for the markdown layer.

If upstream HEAD already matches current_sha, prints a brief
"Status: already up-to-date" block and exits 0 (no diff, no scan).
EOF
}

if ! command -v jq &> /dev/null; then
    echo "ERROR: jq is required" >&2
    exit 1
fi
if ! command -v git &> /dev/null; then
    echo "ERROR: git is required" >&2
    exit 1
fi

NAME=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
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
    echo "ERROR: name is required" >&2
    usage >&2
    exit 1
fi

if ! sigil_manifest_has "${NAME}"; then
    echo "ERROR: no manifest entry named '${NAME}'" >&2
    echo "       Run /sigil:status to list known names." >&2
    exit 1
fi

ENTRY="$(sigil_manifest_get "${NAME}")"
KIND="$(jq -r '.kind' <<<"${ENTRY}")"
SOURCE="$(jq -r '.source // empty' <<<"${ENTRY}")"
CURRENT_SHA="$(jq -r '.current_sha // empty' <<<"${ENTRY}")"
BRANCH="$(jq -r '.branch // empty' <<<"${ENTRY}")"
SUBPATH="$(jq -r '.path // empty' <<<"${ENTRY}")"

if [[ "${KIND}" == "untracked" ]]; then
    echo "ERROR: '${NAME}' is kind=untracked; Sigil cannot update it (no source URL)." >&2
    echo "       Remove it with /sigil:remove and re-add via /sigil:add to track." >&2
    exit 1
fi

if [[ -z "${SOURCE}" || -z "${CURRENT_SHA}" ]]; then
    echo "ERROR: manifest entry '${NAME}' is missing source or current_sha." >&2
    exit 1
fi

sigil_vexscan_require_installed || exit 1
sigil_ensure_state_dir

STAGE_ROOT="$(mktemp -d "${SIGIL_STAGING_DIR}/update-XXXXXX")"
CLONE_DIR="${STAGE_ROOT}/repo"
SCAN_JSON="${STAGE_ROOT}/scan.json"
DIFF_FILE="${STAGE_ROOT}/diff.patch"

echo "Cloning ${SOURCE}..." >&2
# Full clone — we need both upstream HEAD and the approved SHA in
# history to compute a diff. /sigil:check uses shallow because no diff;
# /sigil:update needs depth.
if [[ -n "${BRANCH}" ]]; then
    if ! git clone --quiet -b "${BRANCH}" "${SOURCE}" "${CLONE_DIR}" 2>/dev/null; then
        # Fall back to default branch + checkout (handles arbitrary SHAs as branch).
        if ! git clone --quiet "${SOURCE}" "${CLONE_DIR}" 2>/dev/null; then
            rm -rf "${STAGE_ROOT}"
            echo "ERROR: failed to clone ${SOURCE}" >&2
            exit 1
        fi
        if ! git -C "${CLONE_DIR}" checkout --quiet "${BRANCH}" 2>/dev/null; then
            rm -rf "${STAGE_ROOT}"
            echo "ERROR: failed to checkout '${BRANCH}' in ${SOURCE}" >&2
            exit 1
        fi
    fi
else
    if ! git clone --quiet "${SOURCE}" "${CLONE_DIR}" 2>/dev/null; then
        rm -rf "${STAGE_ROOT}"
        echo "ERROR: failed to clone ${SOURCE}" >&2
        exit 1
    fi
fi

NEW_SHA="$(git -C "${CLONE_DIR}" rev-parse HEAD)"

# Already up-to-date short circuit. No diff to compute, no scan to run.
if [[ "${NEW_SHA}" == "${CURRENT_SHA}" ]]; then
    rm -rf "${STAGE_ROOT}"
    cat <<EOF
=== Sigil update ===
Name:        ${NAME}
URL:         ${SOURCE}
Status:      already up-to-date
Old commit:  ${CURRENT_SHA}
New commit:  ${NEW_SHA}
EOF
    exit 0
fi

# Verify the approved SHA is reachable from the clone. If not (force-push,
# rewritten history, deleted branch), we can't compute a meaningful diff
# and the user must re-approve via /sigil:remove + /sigil:add.
if ! git -C "${CLONE_DIR}" cat-file -e "${CURRENT_SHA}" 2>/dev/null; then
    rm -rf "${STAGE_ROOT}"
    cat >&2 <<EOF
ERROR: approved commit ${CURRENT_SHA} is not reachable in the upstream clone.
       This usually means the upstream branch was force-pushed or rewritten,
       or the commit was on a now-deleted branch.

       To proceed, /sigil:remove '${NAME}' and re-add it with the desired
       ref via /sigil:add — that's a fresh full review, which is the right
       call when the history has changed under you.
EOF
    exit 1
fi

# Resolve the recorded subpath, with the same physical-path canonicalization
# guard sigil-check.sh uses (defense against symlink escape).
if [[ -n "${SUBPATH}" ]]; then
    if [[ "${SUBPATH}" == /* ]]; then
        rm -rf "${STAGE_ROOT}"
        echo "ERROR: manifest path is absolute (refusing): ${SUBPATH}" >&2
        exit 1
    fi
    REPO_DIR="$(cd "${CLONE_DIR}/${SUBPATH}" 2>/dev/null && pwd -P)" || {
        rm -rf "${STAGE_ROOT}"
        echo "ERROR: manifest path '${SUBPATH}' does not exist or is not a directory" >&2
        exit 1
    }
    ABS_CLONE="$(cd "${CLONE_DIR}" && pwd -P)"
    if [[ "${REPO_DIR}" != "${ABS_CLONE}" && "${REPO_DIR}" != "${ABS_CLONE}/"* ]]; then
        rm -rf "${STAGE_ROOT}"
        echo "ERROR: manifest path '${SUBPATH}' escapes the clone directory (possibly via symlink)" >&2
        exit 1
    fi
else
    REPO_DIR="${CLONE_DIR}"
fi

echo "Computing diff..." >&2
DIFF_ARGS=("${CURRENT_SHA}" "${NEW_SHA}")
if [[ -n "${SUBPATH}" ]]; then
    DIFF_ARGS+=("--" "${SUBPATH}")
fi
git -C "${CLONE_DIR}" diff "${DIFF_ARGS[@]}" > "${DIFF_FILE}"

echo "Scanning with vexscan..." >&2
# Capture vexscan's stderr to a sibling file rather than discarding it, so
# a corrupt/empty scan.json downstream can be debugged from the stage dir.
VEXSCAN_ERR="${STAGE_ROOT}/vexscan.err"
if ! sigil_vexscan_run scan "${REPO_DIR}" \
        --ast --deps --skip-deps \
        -f json > "${SCAN_JSON}" 2>"${VEXSCAN_ERR}"; then
    if [[ ! -s "${SCAN_JSON}" ]]; then
        echo "ERROR: vexscan produced no output (stderr at ${VEXSCAN_ERR})" >&2
        # Leave the stage dir so the user can inspect vexscan.err.
        exit 1
    fi
fi

if ! jq empty "${SCAN_JSON}" 2>/dev/null; then
    rm -rf "${STAGE_ROOT}"
    echo "ERROR: vexscan output is not valid JSON (scan.json corrupt)" >&2
    exit 1
fi

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
    echo "=== Sigil update ==="
    echo "Name:        ${NAME}"
    echo "URL:         ${SOURCE}"
    [[ -n "${BRANCH}" ]] && echo "Branch:      ${BRANCH}"
    [[ -n "${SUBPATH}" ]] && echo "Path:        ${SUBPATH}"
    echo "Old commit:  ${CURRENT_SHA}"
    echo "New commit:  ${NEW_SHA}"
    echo "Stage root:  ${STAGE_ROOT}"
    echo "Repo:        ${REPO_DIR}"
    echo "Scan:        ${SCAN_JSON}"
    echo "Diff:        ${DIFF_FILE}"
    echo "Summary:     ${CRITICAL} critical, ${HIGH} high, ${MEDIUM} medium, ${LOW} low, ${INFO} info"
    echo ""
    echo "=== Vexscan findings (JSON) ==="
}
cat "${SCAN_JSON}"
