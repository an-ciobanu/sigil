# Sigil config

Sigil reads user-tunable settings from `~/.sigil/config.json`. The file is **optional** — if it doesn't exist, sensible defaults apply. Edit it directly with your preferred editor when you want to override.

## Schema (version 1)

```json
{
  "version": 1,
  "min_severity": "medium"
}
```

### Fields

#### `version` (integer, required)

Schema version. Currently `1`. Sigil silently falls back to defaults if it sees a version it doesn't understand — so a config bumped by a future Sigil release won't crash an older installation, but won't be honored either.

#### `min_severity` (string, optional)

The severity floor for vexscan findings reported by:

- The SessionStart hook's automatic rescan.
- `/sigil:scan` (when invoked without `--min-severity`).

Allowed values, in increasing severity:

- `info`     — surface all findings, including informational notices.
- `low`      — drop info-only findings.
- `medium`   — **default**. Drops info and low; SessionStart's noise floor.
- `high`     — surface only high and critical findings.
- `critical` — surface only critical findings.

Pick a higher floor if SessionStart notifications get noisy. Pick a lower floor if you want full coverage on every session.

## Examples

Quieter SessionStart (only critical issues mentioned):

```json
{
  "version": 1,
  "min_severity": "critical"
}
```

Full coverage:

```json
{
  "version": 1,
  "min_severity": "info"
}
```

## Validation behavior

If the config file is missing, malformed JSON, on a different schema version, or holds an invalid value for a recognized field, Sigil silently falls back to the defaults — never disrupts a session over a config typo. To inspect the effective values, the easiest path today is to read `config.json` and cross-check against this schema; a future `/sigil:config` command will surface validation issues explicitly.

## Per-call overrides

CLI flags always win over config file values. For example, `/sigil:scan --min-severity high` ignores the config's `min_severity` for that one invocation.
