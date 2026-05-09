# Sigil

A trust-gated plugin manager for Claude Code.

Sigil tracks plugins you install from source, vets them with [vexscan](https://github.com/edimuj/vexscan) before install, and surfaces upstream updates without auto-applying them. Every change goes through you.

## Status

**Pre-alpha — under active design.** Nothing is functional yet.

## Why

Claude Code plugins run with the same privileges as your shell. Auto-installing or auto-updating them blindly is a supply-chain risk. Sigil provides:

- A manifest of every plugin you've installed and which git commit you approved
- Pre-install vetting via [vexscan](https://github.com/edimuj/vexscan) static analysis plus Claude diff review
- SessionStart checks that *surface* upstream updates without applying them
- Manual approval as the gate — no auto-updates, ever

## Planned commands

| Command                  | Purpose                                                      |
|--------------------------|--------------------------------------------------------------|
| `/sigil:check <git-url>` | Vet a source before installing (read-only verdict)           |
| `/sigil:add <git-url>`   | Vet, install, and track in manifest                          |
| `/sigil:status`          | Show tracked sources and pending updates                     |
| `/sigil:update [<name>]` | Fetch upstream, diff-review with Claude, install on approval |
| `/sigil:scan`            | Re-run security scan on currently installed plugins          |
| `/sigil:adopt <path>`    | Bring an existing plugin under Sigil's tracking              |
| `/sigil:remove <name>`   | Uninstall and remove from manifest                           |

## How it works

Sigil is a Claude Code plugin: bash scripts under `scripts/`, slash-command definitions under `commands/`, and a `SessionStart` hook. State lives in `~/.sigil/` (manifest, lock, staging area, pinned vexscan binary).

Supported source kinds (extensible by adding a handler module):

- `claude-plugin` — Claude Code plugins, installed by copying into `~/.claude/plugins/`
- `rust-cargo` — Rust binaries, built locally with `cargo build --release`

## License

Sigil is licensed under [GPL-3.0](LICENSE).

Sigil uses [vexscan](https://github.com/edimuj/vexscan) by edimuj, licensed under Apache-2.0. See [THIRD_PARTY_LICENSES/](THIRD_PARTY_LICENSES/) for the full text and attribution of all third-party dependencies.
