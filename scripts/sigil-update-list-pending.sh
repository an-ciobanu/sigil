#!/usr/bin/env bash
# Output the names of tracked sources whose upstream HEAD differs from
# their approved current_sha. Used by /sigil:update bulk mode (no name
# argument) to drive the iteration.
#
# Output: one name per line. Silent (empty stdout) when there's nothing
# pending, when the manifest is empty/missing, or when all entries are
# untracked / up-to-date / unreachable.
#
# Skips:
#   - kind=untracked entries (no source URL)
#   - up-to-date entries
#   - unreachable sources (no network round-trip success)
#
# Doesn't take the lock — read-only walk over the manifest plus network
# calls. Same posture as the SessionStart hook.

set -uo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=lib/state.sh
source "${SCRIPT_DIR}/lib/state.sh"
# shellcheck source=lib/upstream.sh
source "${SCRIPT_DIR}/lib/upstream.sh"

if ! command -v jq &> /dev/null; then exit 0; fi
if ! command -v git &> /dev/null; then exit 0; fi
[[ -f "${SIGIL_MANIFEST_PATH}" ]] || exit 0

while IFS= read -r entry; do
    [[ -z "${entry}" ]] && continue

    name="$(jq -r '.name' <<<"${entry}")"
    source_url="$(jq -r '.source // empty' <<<"${entry}")"
    current_sha="$(jq -r '.current_sha // empty' <<<"${entry}")"

    [[ -z "${source_url}" || -z "${current_sha}" ]] && continue

    # sigil_upstream_status always exits 0 by contract; on network failure
    # it prints "unreachable" rather than erroring. The case below silently
    # drops "uptodate" / "unreachable" — that's the documented behavior;
    # this script is a filter, not a status report.
    raw="$(sigil_upstream_status "${source_url}" "${current_sha}")"
    case "${raw}" in
        "behind "*)
            echo "${name}"
            ;;
    esac
done < <(jq -c '.sources[]' "${SIGIL_MANIFEST_PATH}" 2>/dev/null)
