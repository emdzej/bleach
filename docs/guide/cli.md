# CLI reference

```
bleach <subcommand>

  scan (default)   Measure and tier ~/Library. Read-only.
  tui              Browse interactively, then write a plan or apply directly.
  plan             Write a reviewable removal plan. Read-only.
  apply            Move a plan's paths into a restorable quarantine.
  restore          Move quarantined paths back where they came from.
  quarantine       List the quarantine, or permanently delete old batches.
  rules            Print the effective rules, or write a starter overlay.
```

`scan` is the default subcommand, so bare `bleach` scans.

## Shared scan options

Accepted by `scan`, `tui`, and `plan`:

| Option | Description |
| --- | --- |
| `--rules <path>` | Rules overlay. Default `~/.config/bleach/rules.yaml`. |
| `--fast-inventory` | Skip the `lsregister` dump. Faster, slightly less complete. |
| `--min-size <size>` | Only consider candidates at or above this size. Accepts `500K`, `100M`, `2G`, or raw bytes. |

## bleach scan

Read-only. Measures, attributes, and tiers.

```
bleach scan [--tier <tier>] [--limit <n>] [--by-owner] [--json] [--explain] [--quiet]
```

| Option | Description |
| --- | --- |
| `--tier <tier>` | Show one tier: `protected`, `cache-safe`, `orphan`, `review`, `unknown`. Lenient parsing — `orphan`, `orphan-likely` and `orphaned` all work. |
| `--limit <n>` | Rows to show. Default 40; `0` for all. |
| `--by-owner` | Group rows by owner instead of listing paths. |
| `--json` | Machine-readable output. |
| `--explain` | Print the evidence trail for every row. |
| `--quiet` | Suppress progress on stderr. |

```sh
bleach scan --tier orphan --explain
bleach scan --by-owner --min-size 100M
bleach scan --json | jq '.byTier'
bleach scan --limit 0 --quiet > report.txt
```

Progress goes to stderr, so `bleach scan | less` stays clean.

### JSON shape

```json
{
  "scannedPaths": 4146,
  "totalBytes": 137438953472,
  "elapsedSeconds": 53.6,
  "accessDeniedCount": 649,
  "inventorySummary": "985 owners (612 with bundle IDs), 39 launchd jobs, …",
  "byTier": { "cacheSafe": { "count": 47, "bytes": 13743895347 }, "…": {} },
  "candidates": [ { "path": "…", "tier": "orphanLikely", "evidence": [] } ]
}
```

## bleach tui

```
bleach tui [-o <output>] [--allow-review]
```

| Option | Description |
| --- | --- |
| `-o, --output <path>` | Where to write a plan if you press `w`. Default `bleach-plan.json`. |
| `--allow-review` | Permit `REVIEW` and `UNKNOWN` rows when applying from the TUI. |

See [The TUI](/guide/tui) for keybindings.

## bleach plan

Read-only. Writes JSON.

```
bleach plan [-o <output>] [--tiers <list>] [--stdout]
```

| Option | Description |
| --- | --- |
| `-o, --output <path>` | Default `bleach-plan.json`. |
| `--tiers <list>` | Comma-separated tiers to include. Default `cache-safe,orphan`. |
| `--stdout` | Print instead of writing a file. |

Paths outside `$HOME` are never included, whatever you pass to `--tiers`.

```sh
bleach plan --tiers cache-safe,orphan,review -o plan.json
bleach plan --stdout | jq -r '.entries[].path'
```

## bleach apply

```
bleach apply <plan-path> [--yes] [--mode <mode>] [--allow-review] [--fast-inventory]
```

| Option | Description |
| --- | --- |
| `<plan-path>` | Plan file written by `bleach plan`. |
| `--dry-run` | Show what would happen. **The default** unless `--yes` is given. |
| `--yes` | Actually do it. |
| `--mode <mode>` | `quarantine` (default), `trash`, or `delete`. |
| `--allow-review` | Permit `REVIEW` and `UNKNOWN` entries, refused by default. |
| `--fast-inventory` | Skip `lsregister` when rebuilding the safety inventory. |

```sh
bleach apply plan.json                       # dry run
bleach apply plan.json --yes                 # quarantine
bleach apply plan.json --yes --mode trash
bleach apply plan.json --yes --mode delete   # asks you to type "delete" on a TTY
```

See [Plans & applying](/guide/plans) for the full list of refusal reasons, and
[Disposal modes](/guide/disposal-modes) for the modes.

## bleach restore

```
bleach restore [<batch-id>] [--path <path> ...]
```

| Option | Description |
| --- | --- |
| `<batch-id>` | Batch ID as printed by `apply`. Omit for the most recent. |
| `--path <path>` | Restore only this original path. Repeatable. |

```sh
bleach restore
bleach restore 20260917-114203
bleach restore 20260917-114203 --path ~/.cache/opencode
```

Never overwrites: if the destination exists again, that entry is skipped.

## bleach quarantine

```
bleach quarantine [--purge] [--older-than <days>] [--all] [--yes]
```

| Option | Description |
| --- | --- |
| *(no flags)* | List batches and their contents. |
| `--purge` | Permanently delete batches. Preview unless `--yes`. |
| `--older-than <days>` | Age threshold for `--purge`. Default 30. |
| `--all` | Purge every batch regardless of age. |
| `--yes` | Required to actually purge. |

```sh
bleach quarantine
bleach quarantine --purge --yes
bleach quarantine --purge --older-than 7 --yes
bleach quarantine --purge --all --yes
```

## bleach rules

```
bleach rules [--initialize] [--plugins]
```

| Option | Description |
| --- | --- |
| *(no flags)* | Print the effective rules as YAML. |
| `--initialize` | Write the defaults to `~/.config/bleach/rules.yaml`. |
| `--plugins` | List discovered plugins and any warnings. |

```sh
bleach rules | less
bleach rules --init
bleach rules --plugins
```

## Environment

| Variable | Effect |
| --- | --- |
| `BLEACH_PLUGIN_PATH` | Colon-separated extra plugin directories. |
| `NO_COLOR` | Disable ANSI colour. |
| `TERM=dumb` | Disable ANSI colour. |

Colour is also disabled automatically when stdout isn't a terminal.

## Exit codes

`0` on success. Non-zero on a usage error, an unreadable or version-mismatched
plan, or a missing quarantine batch. A refused plan entry is **not** an error —
refusals are reported and the permitted entries still proceed.

## Files

| Path | Purpose |
| --- | --- |
| `~/.config/bleach/rules.yaml` | Your rules overlay |
| `~/.config/bleach/plugins/` | Plugins |
| `~/.local/state/bleach/quarantine/` | Quarantined batches |
| `~/.local/state/bleach/journal.jsonl` | Append-only log of every removal |
