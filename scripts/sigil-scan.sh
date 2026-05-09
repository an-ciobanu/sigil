#!/usr/bin/env bash
# /sigil:scan entrypoint — re-run vexscan on demand against either a
# named manifest entry's install_path or all of ~/.claude/.
#
# Usage: sigil-scan.sh [<name>] [--min-severity <level>]
#
# Compared to the SessionStart rescan (lightweight: --skip-deps only),
# this is the deep on-demand pass: --ast for obfuscation detection,
# --deps for supply-chain checks, and human-readable CLI output.
#
# No lock — read-only walk of the manifest plus a vexscan read pass.

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
Usage: sigil-scan.sh [<name>] [--min-severity <level>]

  <name>             Optional. If provided, scan the install_path of the
                     manifest entry named <name>. If omitted, scan all of
                     ~/.claude/ (third-party only).

  --min-severity     Severity floor passed through to vexscan. One of
                     info, low, medium (default), high, critical.

Runs with --ast --deps for thorough analysis, plus --skip-deps so
vendored node_modules trees don't drown the signal.
EOF
}

if ! command -v jq &> /dev/null; then
    echo "ERROR: jq is required" >&2
    exit 1
fi

NAME=""
MIN_SEVERITY="medium"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --min-severity)
            shift
            if [[ $# -eq 0 ]]; then
                echo "ERROR: --min-severity requires a value" >&2
                exit 1
            fi
            MIN_SEVERITY="$1"
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

case "${MIN_SEVERITY}" in
    info|low|medium|high|critical) ;;
    *)
        echo "ERROR: --min-severity must be one of: info, low, medium, high, critical (got '${MIN_SEVERITY}')" >&2
        exit 1
        ;;
esac

# Resolve scope.
SCOPE_PATH=""
SCOPE_DESC=""
SCOPE_THIRD_PARTY_ONLY=0
if [[ -n "${NAME}" ]]; then
    if ! sigil_manifest_has "${NAME}"; then
        echo "ERROR: no manifest entry named '${NAME}'" >&2
        echo "       Run /sigil:status to list known names." >&2
        exit 1
    fi
    SCOPE_PATH="$(sigil_manifest_get "${NAME}" | jq -r .install_path)"
    if [[ ! -d "${SCOPE_PATH}" ]]; then
        echo "ERROR: install_path for '${NAME}' is not on disk: ${SCOPE_PATH}" >&2
        echo "       The entry may be stale; consider /sigil:remove '${NAME}'." >&2
        exit 1
    fi
    SCOPE_DESC="${NAME} (${SCOPE_PATH})"
else
    SCOPE_PATH="${HOME}/.claude"
    if [[ ! -d "${SCOPE_PATH}" ]]; then
        echo "ERROR: ${SCOPE_PATH} does not exist; nothing to scan." >&2
        exit 1
    fi
    SCOPE_DESC="all of ~/.claude (third-party only)"
    SCOPE_THIRD_PARTY_ONLY=1
fi

sigil_vexscan_require_installed || exit 1

cat <<EOF
=== Sigil scan ===
Scope:         ${SCOPE_DESC}
Min severity:  ${MIN_SEVERITY}
Flags:         --ast --deps --skip-deps$([[ ${SCOPE_THIRD_PARTY_ONLY} -eq 1 ]] && echo " --third-party-only")

EOF

# Build vexscan args. Named-scope skips --third-party-only because the
# user explicitly asked for that entry; ~/.claude scope adds it so
# Anthropic-shipped components don't dominate the output.
# --quiet suppresses vexscan's INFO-level progress logs ("Loaded 162
# embedded rules", "Scanning with N threads") so the user sees just the
# findings. Errors and warnings still surface.
VEXSCAN_ARGS=("--quiet" "scan" "${SCOPE_PATH}" "--ast" "--deps" "--skip-deps" "--min-severity" "${MIN_SEVERITY}")
if (( SCOPE_THIRD_PARTY_ONLY == 1 )); then
    VEXSCAN_ARGS+=("--third-party-only")
fi
VEXSCAN_ARGS+=("-f" "cli")

# vexscan exit codes:
#   0 — scan completed, no findings at/above fail-on threshold
#   1 — scan completed, findings at/above threshold (a successful scan
#       with results — forward to the user as the answer)
#   anything else — real tooling failure (crash, malformed args, etc.)
set +e
sigil_vexscan_run "${VEXSCAN_ARGS[@]}"
rc=$?
set -e
if [[ "${rc}" -ne 0 && "${rc}" -ne 1 ]]; then
    echo "ERROR: vexscan exited with rc=${rc}" >&2
    exit "${rc}"
fi
