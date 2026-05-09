---
description: Bring a pre-existing plugin under Sigil's tracking as kind=untracked (scan-only, no upstream).
argument-hint: "<path> [--name <name>]"
allowed-tools: "Bash"
---

# /sigil:adopt

Register an existing plugin directory in the Sigil manifest. The entry is recorded as `kind: untracked` — Sigil will include it in security scans, but cannot update it because there's no source URL to track.

Use this for plugins installed before Sigil, or anything you manage outside the source-from-git flow.

## Usage

- `/sigil:adopt <path>` — adopt the plugin at `<path>`, named after its directory.
- `/sigil:adopt <path> --name <name>` — same, but use a custom manifest name.

## Examples

- `/sigil:adopt ~/.claude/plugins/some-plugin`
- `/sigil:adopt ./local-clone --name dev-version`

## Instructions

Run the adopt script and present the output to the user verbatim.

!`${CLAUDE_PLUGIN_ROOT}/scripts/sigil-adopt.sh $ARGUMENTS`
