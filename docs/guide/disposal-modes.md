# Disposal modes

`apply` and the TUI share one execution path, so validation, journalling, and
skip reporting cannot drift between modes.

| `--mode` | What happens | Undo |
| --- | --- | --- |
| `quarantine` *(default)* | Renamed into `~/.local/state/bleach/quarantine` | `bleach restore <batch>` |
| `trash` | Handed to Finder's Trash via `FileManager.trashItem` | Finder — but it still occupies disk until emptied |
| `delete` | Unlinked immediately | none |

## quarantine

The default, and the one to leave alone unless you have a reason.

Paths are **renamed**, not copied. On APFS that's an O(1) metadata operation,
so quarantining 10 GB is instantaneous and trivially reversible — the bytes
never moved.

```sh
bleach apply plan.json --yes
```

```
  quarantined 46 paths · 11.6G

  batch 20260917-114203
  undo:    bleach restore 20260917-114203
  commit:  bleach quarantine --purge --all
```

Because it's a rename on the same volume, it does **not** free space until you
purge. That's the point: you get a window to notice something broke.

See [Quarantine & restore](/guide/quarantine).

## trash

```sh
bleach apply plan.json --yes --mode trash
```

Hands each path to Finder's Trash. Reversible from Finder without bleach
involved, which is useful if you'd rather not learn another undo mechanism.

Two caveats:

- It still occupies disk until you empty the Trash, same as quarantine.
- It survives `bleach quarantine --purge`, because bleach doesn't own it.
  Emptying the Trash is on you.

## delete

```sh
bleach apply plan.json --yes --mode delete
```

Unlinks immediately. No undo.

### It is not a fast path

`delete` runs **exactly the same validation** as every other mode, including
the second per-entry re-check immediately before disposal. This is asserted by
tests rather than left to inspection — `RemovalModeTests` confirms that
`.ssh`, paths outside `$HOME`, and symlinks all survive `--mode delete`, and
that the symlink's target is untouched.

### Confirmation

On an interactive terminal, `--mode delete` additionally requires typing the
word `delete`:

```
  This permanently deletes 11.6G with no undo.
  Type delete to confirm:
```

In the TUI the modal turns red and requires the same word.

In a script, `--yes --mode delete` together are treated as sufficient consent —
two explicit flags, no prompt.

## Journalling

Every mode appends to `~/.local/state/bleach/journal.jsonl`, **including
`delete`**. If someone later asks "what happened to that directory", the answer
should exist even when the bytes don't.

```jsonl
{"id":"20260917-114203","createdAt":"2026-09-17T09:42:03Z","items":[
  {"originalPath":"/Users/you/Library/Caches/lens-desktop-updater",
   "storedName":"<deleted>","sizeBytes":1073741824,"tier":"cacheSafe",
   "reasons":["cacheRule: matches regenerable rule -updater$"]}]}
```

`storedName` records the disposition: a flattened directory name for
quarantine, `<Trash>` for trash, `<deleted>` for delete.

## Which to use

- **Reclaiming space right now, confident about the list** → `delete`, after
  reading the plan.
- **Not sure, want a safety net you control** → `quarantine`, then purge in a
  few weeks.
- **Not sure, prefer Finder's undo to learning bleach's** → `trash`.

The honest recommendation is `quarantine` for the first few runs. Once you've
seen what bleach proposes and found it sensible, `delete` saves you a purge
step.
