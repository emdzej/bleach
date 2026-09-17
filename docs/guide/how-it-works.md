# How it works

## The core problem

There is no link on disk from `~/Library/Application Support/Foo` back to an
app. Directory names are a convention, not a reference — some are reverse-DNS
bundle identifiers, some are product names, some are neither.

So "is this an orphan?" cannot be *computed*. It can only be argued for from
evidence. bleach is built around that: it gathers signals from several
independent sources, records each one with a weight and a human-readable
reason, and sorts the result into [tiers](/guide/tiers) by how safe removal is.

You read the evidence. It never decides alone.

## The pipeline

```
scan ──→ resolve ──→ classify ──→ plan ──→ apply
measure   attribute    tier      artifact  execute
```

Each stage is separable, and the boundary between `plan` and `apply` is the
important one: scanning is heuristic, so its conclusions get written to a file
a human reads before anything happens. `apply` performs no analysis of its own
beyond refusing entries it considers unsafe.

## 1. Inventory: what is installed?

Owner attribution starts with a union of sources, each weighted by how
strongly it implies the owner is *currently present*:

| Source | Weight | Notes |
| --- | --- | --- |
| Running processes (`ps`) | 1.00 | Anything with a live process is untouchable |
| Filesystem walk, Spotlight (`mdfind`) | 0.95 | ~450 app bundles, effectively instant |
| Homebrew Caskroom / Cellar | 0.90 | Often the only name matching a human-named directory |
| launchd agents and daemons | 0.70 | A job pointing at a live binary proves the owner exists |
| LaunchServices (`lsregister -dump`) | 0.60 | Most complete, ~4.5 s, but retains stale entries |
| Installer receipts (`/var/db/receipts`) | 0.25 | Survives uninstallation |

That last row earns its weight. Slack was uninstalled on the development
machine but left a pkg receipt behind. Without down-weighting receipts, its
1.1 GB container would look owned and stay protected forever.

Sources are collected concurrently, because `lsregister -dump` takes several
seconds and everything else is nearly free.

## 2. Resolve: who owns this directory?

Tried in order, stopping at the first that lands:

1. **Alias table** — for names normalisation can't bridge, like
   `Code - Insiders` → `com.microsoft.VSCodeInsiders`.
2. **The name is a bundle ID** — `ai.opencode.desktop`, `dev.warp.Warp-Stable`.
   Requires three dot-separated segments and a plausible leading segment, so
   `IntelliJIdea2025.3` isn't mistaken for one.
3. **App Group team prefix** — `2BUA8C4S2C.com.1password.browser-helper`
   resolves via the 10-character team ID from the app's code signature.
4. **Canonical name match** — lowercased, punctuation stripped.
5. **Version-stripped match** — `IntelliJIdea2025.3` and `IntelliJIdea2026.2`
   both reduce to `intellijidea`, which is what makes version-orphan detection
   possible. Requires a stem of at least four characters; without that floor,
   `.m2` reduces to `m` and cheerfully matches a Homebrew formula called `m4`.
6. **Nothing matched** — recorded as evidence, not as failure.

## 3. Corroborate: signals independent of the name

These are what allow bleach to act on a directory whose name resolved to
nothing at all:

- **Newest mtime of anything inside.** The directory's own mtime is
  unreliable — it changes when unrelated metadata churns.
- **`~/Library/Preferences/<id>.plist`** and
  **`Saved Application State/<id>.savedState`** only exist if the app has run.
- **A launchd job** whose binary still exists, or conspicuously doesn't.
- **The sibling set.** One owner's state showing up consistently across
  Application Support, Caches, Containers, Preferences and HTTPStorages is
  itself strong evidence the identifier is right — and the combined size is
  what makes the reclaim worthwhile.
- **A registered `.app` bundle inside.** Self-updating apps keep their real
  binary under Application Support. Raycast's lives in
  `~/Library/Application Support/com.raycast.macos/Updates/…`, so deleting that
  directory uninstalls the app. Hard-protected.

## 4. Classify

Rules run most-protective-first, in a fixed order. Score is only a tiebreak
*within* a tier — a pile of weak "looks abandoned" signals must never outvote
a single protected-path match. See [Tiers](/guide/tiers).

Two post-passes then run over the whole set:

**Version retention** — among candidates reducing to the same stem, keep the
newest and mark the rest superseded. This only demotes *soft* protections:
"its owner is installed" is soft and can be overridden, while "a process is
running from here" is hard and cannot.

**Overlap detection** — a candidate containing other candidates is excluded
from totals and from every actionable tier. Its bytes are already counted by
its children, and acting on the parent would take the children's protected
siblings along with it. These rows show `⊂` in the TUI.

## 5. Plan, then apply

`plan` writes JSON. `apply` re-derives every safety property from scratch,
because a plan can be hours old, hand-edited, or copied from another machine:

- absolute, standardised path (blocks `..` traversal)
- inside `$HOME`, and not `$HOME` itself
- exists, and is not a symlink
- doesn't match a *current* protection rule
- no running process beneath it, no registered app bundle inside
- tier is actionable, unless `--allow-review`
- hasn't grown more than 1.5× since the plan was written

This is deliberately redundant with the classifier. The classifier decides
what to *propose*; the validator decides what is *permitted*.

## Where the numbers come from

Sizes are **allocated** size, walked natively with hardlinks de-duplicated per
candidate, so totals line up with `du`. Symlinks are never followed — an early
bug where `skipDescendants()` was called on symlink entries silently skipped
the rest of each directory level and undercounted Homebrew's cache by 11 GB.
