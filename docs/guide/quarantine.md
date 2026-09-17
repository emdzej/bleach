# Quarantine & restore

## Where it lives

```
~/.local/state/bleach/
├── journal.jsonl                        # append-only; every mode, including delete
└── quarantine/
    └── 20260917-114203/                 # batch id = timestamp
        ├── manifest.json                # original paths, sizes, tiers, reasons
        ├── Library-Caches-lens-desktop-updater
        └── .local-share-opencode-bin
```

The directory is created lazily on first `apply`. Stored names are the original
path with `/` flattened to `-`, so the quarantine stays browsable by hand — if
bleach itself ever breaks, you can put things back with `mv`.

Batch IDs are timestamps, so they sort chronologically.

## Inspecting

```sh
bleach quarantine
```

```
  quarantine  /Users/you/.local/state/bleach/quarantine

  20260917-114203    11.6G   46 paths · 17/09/2026, 11:42
       1.4G   /Users/you/.cache/opencode
       1.1G   /Users/you/.local/share/opencode/bin
       1.0G   /Users/you/Library/Caches/lens-desktop-updater
      … 43 more

  restore: bleach restore <batch>   ·   commit: bleach quarantine --purge
```

## Restoring

```sh
bleach restore                      # the most recent batch
bleach restore 20260917-114203      # a specific batch
bleach restore 20260917-114203 --path /Users/you/.cache/opencode   # one path
```

`--path` is repeatable, so you can pull back just the one thing that broke
without undoing the whole batch.

### It never clobbers

If the app recreated its directory after the removal, restore **skips** that
entry rather than overwriting:

```
  restored 45 paths from batch 20260917-114203
  skip  /Users/you/.cache/opencode — destination already exists
```

Which copy wins is your decision, not bleach's. The quarantined copy stays
where it is until you deal with it.

## Purging

This is the only code path in bleach that destroys data, and it only ever
touches paths inside its own quarantine directory.

```sh
bleach quarantine --purge                        # preview: batches older than 30 days
bleach quarantine --purge --yes                  # do it
bleach quarantine --purge --older-than 7 --yes   # different threshold
bleach quarantine --purge --all --yes            # everything, regardless of age
```

Without `--yes` it prints what would go and stops:

```
  20260917-114203    11.6G   46 paths

  This permanently deletes 11.6G and cannot be undone.
  Re-run with --yes to confirm.
```

## Space accounting

A quarantined path still occupies disk — it was renamed, not removed. `du` on
your home directory won't change until you purge.

That's the trade: you get a window in which everything is reversible, at the
cost of not seeing the space back yet. If you'd rather have the space
immediately, use [`--mode delete`](/guide/disposal-modes) and rely on having
read the plan.

## A suggested rhythm

```sh
bleach scan --tier orphan          # look
bleach plan -o plan.json           # write
less plan.json                     # read
bleach apply plan.json --yes       # quarantine
# …use your machine normally for a week…
bleach quarantine --purge --all --yes   # commit
```

If something breaks in that week, `bleach restore` puts it back and you've lost
nothing.
