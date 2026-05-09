#!/usr/bin/env bash
# SessionStart hook. Two concerns folded into one notification:
#   1. Upstream check (SIGIL-4.1): per tracked source, git ls-remote and
#      compare to the approved current_sha. Count behind / unreachable.
#   2. Vexscan rescan (SIGIL-5.1): run vexscan over ~/.claude/ with
#      lightweight flags (--third-party-only --skip-deps --min-severity
#      medium) so a rule-set bump catches issues in plugins that were
#      clean at install time. Skipped silently if vexscan is not
#      installed — the SessionStart hook should never disrupt the
#      session over Sigil-internal state.
#
# Output contract (Claude Code SessionStart hook):
#   stdout: JSON {"userMessage": "...", "systemMessage": "..."} on
#           anything to report; empty when fully quiet.
#
# This hook does NOT acquire the lock — it's a read-only walk over the
# manifest (atomic snapshot via jq) plus network calls and a vexscan
# read of ~/.claude/. A concurrent /sigil:update or /sigil:add will
# simply yield slightly stale numbers here, which is acceptable.
#
# Performance note: ls-remote is serial across sources, vexscan is
# single-process. SIGIL-5.x will add timestamp caching to avoid
# hammering remotes / re-scanning unchanged plugin trees on every
# session.

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
# shellcheck source=lib/vexscan/lib.sh
source "${SCRIPT_DIR}/lib/vexscan/lib.sh"

# Stay silent (exit 0, no output) if anything blocks our work — this
# hook should never fail in a way that disrupts the user's session.
quiet_exit() { exit 0; }

if ! command -v jq &> /dev/null; then quiet_exit; fi
if ! command -v git &> /dev/null; then quiet_exit; fi

UPDATES=0
UNREACHABLE=0

# ── Upstream check (only runs if a manifest exists) ─────────────────────
if [[ -f "${SIGIL_MANIFEST_PATH}" ]]; then
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
fi

# ── Vexscan rescan of ~/.claude/ ────────────────────────────────────────
# Lightweight flags so SessionStart stays fast: skip --ast (obfuscation
# detection is slow) and --deps (supply-chain lookups). Users wanting a
# deeper analysis run /sigil:scan (SIGIL-5.2). --third-party-only skips
# Anthropic-shipped components; --skip-deps skips node_modules trees.
CRITICAL=0
HIGH=0
MEDIUM=0
# Silent skip on a stale vexscan pin (binary not installed at the new
# pinned path) is intentional — SessionStart never disrupts the session.
# The user will see an actionable error the next time they run
# /sigil:check, /sigil:scan, or any flow that requires vexscan.
if [[ -d "${HOME}/.claude" ]] && sigil_vexscan_is_installed; then
    SCAN_OUTPUT="$(sigil_vexscan_run scan "${HOME}/.claude" \
        --third-party-only --skip-deps --min-severity medium \
        -f json 2>/dev/null)" || true

    if [[ -n "${SCAN_OUTPUT}" ]] && jq empty <<<"${SCAN_OUTPUT}" 2>/dev/null; then
        if read -r CRITICAL HIGH MEDIUM <<< "$(jq -r '
            [(.results // [])[].findings[]?.severity] as $s |
            [
              (($s | map(select(. == "critical")) | length) // 0),
              (($s | map(select(. == "high"))     | length) // 0),
              (($s | map(select(. == "medium"))   | length) // 0)
            ] | @tsv
        ' <<<"${SCAN_OUTPUT}" 2>/dev/null)"; then
            :
        else
            CRITICAL=0
            HIGH=0
            MEDIUM=0
        fi
    fi
fi
TOTAL_FINDINGS=$((CRITICAL + HIGH + MEDIUM))

# Silent when there's nothing for the user to act on.
if (( UPDATES == 0 && UNREACHABLE == 0 && TOTAL_FINDINGS == 0 )); then
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
if (( TOTAL_FINDINGS > 0 )); then
    # Build a per-severity breakdown only when there's mixed severity to
    # surface; for single-severity totals, the breakdown would just echo
    # the count and adds noise.
    breakdown=()
    (( CRITICAL > 0 )) && breakdown+=("${CRITICAL} critical")
    (( HIGH > 0 ))     && breakdown+=("${HIGH} high")
    (( MEDIUM > 0 ))   && breakdown+=("${MEDIUM} medium")

    if (( TOTAL_FINDINGS == 1 )); then
        finding_part="1 security finding"
    else
        finding_part="${TOTAL_FINDINGS} security findings"
    fi
    if (( ${#breakdown[@]} > 1 )); then
        # Join breakdown with comma+space.
        bd=""
        for j in "${!breakdown[@]}"; do
            if (( j > 0 )); then bd+=", "; fi
            bd+="${breakdown[j]}"
        done
        finding_part="${finding_part} (${bd})"
    fi
    parts+=("${finding_part}")
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
