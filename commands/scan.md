---
description: Re-run vexscan on demand against a tracked source or all of ~/.claude/.
argument-hint: "[<name>] [--min-severity <level>]"
allowed-tools: "Bash"
---

# /sigil:scan

Re-run vexscan on demand. Useful when:
- A vexscan rule update lands and you want a deep rescan beyond what SessionStart did
- You suspect a specific plugin and want a focused report
- You want to spot-check before publishing or sharing

## Usage

- `/sigil:scan` — scan all of `~/.claude/` (third-party only).
- `/sigil:scan <name>` — scan the install_path of the named manifest entry. Find names with `/sigil:status`.
- `/sigil:scan [<name>] --min-severity <level>` — set the severity floor. One of `info`, `low`, `medium` (default), `high`, `critical`.

Compared to the SessionStart rescan (lightweight, no `--ast`/`--deps`), this is the deep pass: AST-based obfuscation detection plus supply-chain dependency checks. Output is vexscan's CLI format, presented to the user verbatim.

## Instructions

Run the scan script and present the output to the user verbatim. Do not interpret or summarize — vexscan's output is the answer.

!`${CLAUDE_PLUGIN_ROOT}/scripts/sigil-scan.sh $ARGUMENTS`
