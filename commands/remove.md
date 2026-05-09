---
description: Uninstall a Sigil-tracked source and remove it from the manifest.
argument-hint: "<name>"
allowed-tools: "Bash"
---

# /sigil:remove

Remove a tracked source from Sigil. For tracked entries (`kind=claude-plugin` or `rust-cargo`), this also deletes the installed files. For `kind=untracked` entries (adopted via `/sigil:adopt`), only the manifest entry is removed — the original files are left alone, since Sigil didn't put them there.

## Usage

- `/sigil:remove <name>` — remove the entry named `<name>`.

Find names with `/sigil:status`.

## Safety

Sigil refuses to delete an `install_path` that isn't strictly under `$HOME`. This guards against a malformed manifest pointing at a system directory.

## Instructions

Run the remove script and present the output to the user verbatim.

!`${CLAUDE_PLUGIN_ROOT}/scripts/sigil-remove.sh $ARGUMENTS`
