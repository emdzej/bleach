# Plans & applying

## Why a plan file

Scanning is heuristic. Rather than hide that behind a prompt, bleach writes its
conclusions to a file you read and edit, and `apply` executes that file and
does no analysis of its own.

This makes the tool auditable, diffable, and testable without a filesystem —
and it turns "trust the heuristics" into "read the list".

## Writing one

```sh
bleach plan -o plan.json
```

By default only `CACHE-SAFE` and `ORPHAN?` entries are included. Everything
else has to be asked for:

```sh
bleach plan --tiers cache-safe,orphan,review -o plan.json
bleach plan --min-size 100M -o plan.json
bleach plan --stdout | jq '.entries[] | .path'
```

Paths outside `$HOME` are never included, whatever you pass to `--tiers`.

```
  wrote plan.json
  31 entries      13.6G

     1.4G   CACHE-SAFE /Users/you/.cache/opencode
     1.1G   CACHE-SAFE /Users/you/.local/share/opencode/bin
     854M   ORPHAN?    …/Library/Application Support/com.isaacmarovitz.Whisky
    … 19 more

  Read the plan before applying. Then:
    bleach apply plan.json --dry-run
    bleach apply plan.json
```

## The format

```json
{
  "version": 1,
  "createdAt": "2026-09-17T08:00:00Z",
  "home": "/Users/you",
  "entries": [
    {
      "path": "/Users/you/Library/Application Support/com.isaacmarovitz.Whisky",
      "sizeBytes": 895483904,
      "tier": "orphanLikely",
      "ownerLabel": null,
      "newestMTime": "2025-01-08T14:22:03Z",
      "reasons": [
        "noOwnerFound: com.isaacmarovitz.Whisky looks like a bundle ID but no installed app claims it",
        "stale: nothing modified inside for 617 days"
      ]
    }
  ]
}
```

`reasons` is copied from the evidence trail so the plan is reviewable without
re-running a scan. Delete entries you disagree with — hand-editing is the
expected workflow, not an abuse of it.

## Applying

```sh
bleach apply plan.json              # dry run — the default
bleach apply plan.json --yes        # actually do it
```

Dry run is the default. `--yes` is required to change anything.

```
  plan: plan.json  written 17/09/2026, 10:00
  1 permitted · 3.0M · 3 refused

  skip 1000B   /Users/you/.ssh — ".ssh" is a protected name
  skip  100B   /etc/hosts — outside your home directory
  skip  100B   …/.bleach/../.bleach/victim — path is not standardised (possible traversal)

  move  3.0M   /Users/you/.bleach-test/victim

  dry run — nothing changed. Re-run with --yes to proceed.
```

## What `apply` re-checks

A plan is a file. It can be hours old, hand-edited, or copied from another
machine — so `apply` trusts nothing in it except the path, and re-derives every
safety property from scratch:

| Check | Refusal |
| --- | --- |
| Absolute path | *not an absolute path* |
| Standardised (blocks `..`) | *path is not standardised (possible traversal)* |
| Inside `$HOME` | *outside your home directory* |
| Not `$HOME` itself | *is your home directory* |
| Exists | *no longer exists* |
| Not a symlink | *is a symlink* |
| No current protection rule matches | *now matches protected path rule "…"* |
| Not a protected name | *".ssh" is a protected name* |
| No protected bundle prefix | *bundle ID matches protected prefix com.apple.* |
| No running process beneath it | *a process is running from this path* |
| No registered `.app` inside | *an installed app bundle lives inside* |
| Tier is actionable | *tier REVIEW needs --allow-review to apply* |
| Hasn't grown >1.5× | *grew 2.3× since the plan was written; rescan first* |
| Fully readable | *partially unreadable; grant Full Disk Access and rescan* |

Deliberately redundant with the classifier. The classifier decides what to
*propose*; this decides what is *permitted*.

Validation runs twice: once up front so you see the whole picture, and again
immediately before each individual disposal, to close the window between the
summary you read and the act itself.

## Options

```sh
bleach apply plan.json --yes --mode trash    # see Disposal modes
bleach apply plan.json --yes --allow-review  # permit REVIEW / UNKNOWN entries
bleach apply plan.json --yes --fast-inventory  # skip lsregister when rebuilding inventory
```

`--allow-review` exists because `REVIEW` is where bleach says it isn't sure.
Requiring a flag makes that an explicit decision.
