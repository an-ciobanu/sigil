#!/usr/bin/env bash
# /sigil:status entrypoint — print Sigil's tracked-source inventory.
# Usage: sigil-status.sh [--offline]

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=lib/manifest.sh
source "${SCRIPT_DIR}/lib/manifest.sh"
# shellcheck source=lib/upstream.sh
source "${SCRIPT_DIR}/lib/upstream.sh"

if ! command -v jq &> /dev/null; then
    echo "ERROR: jq is required for /sigil:status" >&2
    exit 1
fi

OFFLINE=0
for arg in "$@"; do
    case "${arg}" in
        --offline) OFFLINE=1 ;;
        *) ;;  # ignore unknown args silently
    esac
done

count="$(sigil_manifest_count)"
if [[ "${count}" == "0" ]]; then
    echo "No sources tracked. Add one with /sigil:add or /sigil:adopt."
    exit 0
fi

if [[ "${OFFLINE}" == "1" ]]; then
    echo "Tracked sources (${count}, offline mode):"
else
    echo "Tracked sources (${count}):"
fi
echo

# Capture names first so a list_names failure surfaces immediately rather
# than silently truncating the output (process substitution swallows the
# failure under set -e).
names="$(sigil_manifest_list_names)" || exit 1

# Build header + rows separated by tabs, then format with `column -t`.
{
    printf 'NAME\tKIND\tSHA\tSTATUS\tSOURCE\n'
    while IFS= read -r name; do
        [[ -z "${name}" ]] && continue
        entry="$(sigil_manifest_get "${name}")"
        kind="$(jq -r '.kind' <<<"${entry}")"
        current_sha="$(jq -r '.current_sha // empty' <<<"${entry}")"
        source_url="$(jq -r '.source // empty' <<<"${entry}")"

        local_short_sha="${current_sha:0:7}"
        [[ -z "${local_short_sha}" ]] && local_short_sha="-"
        [[ -z "${source_url}" ]] && source_url="-"

        if [[ "${kind}" == "untracked" ]]; then
            status="scan-only"
        elif [[ "${OFFLINE}" == "1" ]]; then
            status="(offline)"
        else
            raw="$(sigil_upstream_status "${source_url}" "${current_sha}")"
            case "${raw}" in
                uptodate)
                    status="up-to-date"
                    ;;
                "behind "*)
                    new_sha="${raw#behind }"
                    status="update: ${new_sha:0:7}"
                    ;;
                unreachable)
                    status="unreachable"
                    ;;
                *)
                    status="?"
                    ;;
            esac
        fi

        printf '%s\t%s\t%s\t%s\t%s\n' \
            "${name}" "${kind}" "${local_short_sha}" "${status}" "${source_url}"
    done <<<"${names}"
} | column -t -s "$(printf '\t')"
