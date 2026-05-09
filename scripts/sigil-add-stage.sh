#!/usr/bin/env bash
# /sigil:add staging step — extract the URL from the user's args (which
# may contain --name / --kind / --accept-risky for the install step) and
# delegate to sigil-check.sh, which already does clone + scan + labeled
# output. The markdown layer separately spawns the verdict subagent and
# gates on the result before calling sigil-add-install.sh.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

URL=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --name|--kind)
            shift
            [[ $# -gt 0 ]] && shift || true
            continue
            ;;
        --accept-risky)
            ;;
        --help|-h)
            cat <<EOF
Usage: sigil-add-stage.sh <git-url> [--name <name>] [--kind <kind>] [--accept-risky]

Used internally by /sigil:add. Extracts the URL and delegates the actual
clone+scan to sigil-check.sh; ignores the install-time flags.
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

exec "${SCRIPT_DIR}/sigil-check.sh" "${URL}"
