#!/usr/bin/env bash
# SessionStart hook: for each tracked source in the manifest, ask the
# remote for its current HEAD via git ls-remote. If any sources are
# behind their approved SHA or unreachable, emit a single non-blocking
# summary line. Stay silent otherwise — the hook fires every session,
# noise is the enemy.
#
# Output contract (Claude Code SessionStart hook):
#   stdout: JSON {"userMessage": "...", "systemMessage": "..."} on
#           anything to report; empty when fully quiet.
#
# This hook does NOT acquire the lock — it's a read-only walk over the
# manifest (atomic snapshot via jq) plus network calls to remotes. A
# concurrent /sigil:update will simply yield slightly stale numbers
# here, which is acceptable.
#
# Performance note: ls-remote is serial across sources for v1. SIGIL-5.x
# will add timestamp caching to avoid hammering remotes on every session.

set -uo pipefail

# Drain stdin defensively. Claude Code feeds SessionStart hooks JSON on
# stdin; if we don't read it, the writer's close usually unblocks anyway,
# but the explicit drain matches the working reference (vexscan-claude-code)
# and avoids any hypothetical pipe-buffer wedge.
_=$(cat 2>/dev/null || true)

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=lib/state.sh
source "${SCRIPT_DIR}/lib/state.sh"
# shellcheck source=lib/upstream.sh
source "${SCRIPT_DIR}/lib/upstream.sh"

# Stay silent (exit 0, no output) if anything blocks our work — this
# hook should never fail in a way that disrupts the user's session.
quiet_exit() { exit 0; }

if ! command -v jq &> /dev/null; then quiet_exit; fi
if ! command -v git &> /dev/null; then quiet_exit; fi
[[ -f "${SIGIL_MANIFEST_PATH}" ]] || quiet_exit

UPDATES=0
UNREACHABLE=0

while IFS= read -r entry; do
    [[ -z "${entry}" ]] && continue

    source_url="$(jq -r '.source // empty' <<<"${entry}")"
    current_sha="$(jq -r '.current_sha // empty' <<<"${entry}")"

    # Skip kind=untracked entries (no source URL to query) and any
    # malformed entries missing required fields.
    [[ -z "${source_url}" || -z "${current_sha}" ]] && continue

    raw="$(sigil_upstream_status "${source_url}" "${current_sha}")"
    case "${raw}" in
        uptodate)    ;;
        "behind "*)  UPDATES=$((UPDATES + 1)) ;;
        unreachable) UNREACHABLE=$((UNREACHABLE + 1)) ;;
    esac
done < <(jq -c '.sources[]' "${SIGIL_MANIFEST_PATH}" 2>/dev/null)

# Silent when there's nothing for the user to act on.
if (( UPDATES == 0 && UNREACHABLE == 0 )); then
    quiet_exit
fi

parts=()
if (( UPDATES == 1 )); then
    parts+=("1 update available")
elif (( UPDATES > 1 )); then
    parts+=("${UPDATES} updates available")
fi
if (( UNREACHABLE == 1 )); then
    parts+=("1 source unreachable")
elif (( UNREACHABLE > 1 )); then
    parts+=("${UNREACHABLE} sources unreachable")
fi

# Comma-separated join.
SUMMARY=""
for i in "${!parts[@]}"; do
    if (( i > 0 )); then SUMMARY+=", "; fi
    SUMMARY+="${parts[i]}"
done
MSG="[Sigil] ${SUMMARY}. Run /sigil:status for details."

# jq does the JSON quoting/escaping; never hand-build JSON with raw values.
jq -nc --arg msg "${MSG}" '{userMessage: $msg, systemMessage: $msg}'
