# Third-Party Licenses

Sigil is licensed under [GPL-3.0](../LICENSE), but it depends on third-party software with separate licenses. Those licenses are reproduced here in full, in compliance with the redistribution terms of each.

## vexscan

- **Project:** [edimuj/vexscan](https://github.com/edimuj/vexscan)
- **License:** Apache License 2.0
- **License text:** [vexscan/LICENSE](vexscan/LICENSE)
- **How Sigil uses it:** Sigil invokes the `vexscan` CLI binary as a subprocess to perform static security analysis on Claude Code plugins. Sigil does not link against vexscan source or distribute modified vexscan binaries.

Apache-2.0 is one-way compatible with GPL-3.0; combined distributions are GPL-3.0.
