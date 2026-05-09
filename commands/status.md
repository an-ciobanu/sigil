---
description: Show the current state of Sigil-tracked sources (kind, current SHA, update status).
argument-hint: "[--offline]"
allowed-tools: "Bash"
---

# /sigil:status

Show the current state of Sigil-tracked sources.

## Usage

- `/sigil:status` — list every tracked source and check upstream for updates.
- `/sigil:status --offline` — skip the upstream check (faster, no network).

## What you'll see

Per source: `name`, `kind`, current SHA (short), status, and source URL.
Status is one of:
- `up-to-date` — current_sha matches upstream HEAD
- `update: <sha>` — upstream has a newer commit available
- `unreachable` — couldn't contact the source remote
- `scan-only` — untracked entry (no source URL; manage via /sigil:adopt)

## Instructions

Run the status script and present the output to the user verbatim. Do not interpret or summarize — the script's output is the answer.

!`${CLAUDE_PLUGIN_ROOT}/scripts/sigil-status.sh $ARGUMENTS`
