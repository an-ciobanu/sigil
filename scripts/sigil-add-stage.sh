#!/usr/bin/env bash
# /sigil:add staging step — extract the URL plus the staging-relevant
# flags from the user's args and delegate to sigil-check.sh. Install-time
# flags (--name, --kind, --accept-risky) are consumed and dropped here;
# clone-time flags (--branch, --path) are forwarded to sigil-check.sh.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

URL=""
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name|--kind)
            # Install-time flag with a value; consume both and drop.
            shift
            [[ $# -gt 0 ]] && shift || true
            continue
            ;;
        --accept-risky)
            # Install-time boolean flag; drop.
            ;;
        --branch|--path)
            # Clone-time flag with a value; forward to sigil-check.sh.
            EXTRA_ARGS+=("$1")
            shift
            if [[ $# -gt 0 ]]; then
                EXTRA_ARGS+=("$1")
            fi
            ;;
        --help|-h)
            cat <<EOF
Usage: sigil-add-stage.sh <git-url> [--branch <ref>] [--path <subpath>]
                          [--name <name>] [--kind <kind>] [--accept-risky]

Used internally by /sigil:add. Forwards --branch and --path to
sigil-check.sh; consumes and ignores install-time flags.
EOF
            exit 0
            ;;
        --*)
            ;;  # unknown flag, ignore for staging
        *)
            if [[ -z "${URL}" ]]; then
                URL="$1"
            fi
            ;;
    esac
    shift
done

if [[ -z "${URL}" ]]; then
    echo "ERROR: git URL is required" >&2
    exit 1
fi

# Bash 3.2 + set -u: an empty array's @-expansion is unbound. Branch on length.
if (( ${#EXTRA_ARGS[@]} > 0 )); then
    exec "${SCRIPT_DIR}/sigil-check.sh" "${URL}" "${EXTRA_ARGS[@]}"
else
    exec "${SCRIPT_DIR}/sigil-check.sh" "${URL}"
fi
