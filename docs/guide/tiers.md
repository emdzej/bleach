# Tiers

Every candidate lands in exactly one tier. The assignment is rule-driven and
most-protective-first: bleach assigns the *safest* tier that applies, never the
most aggressive one.

| Tier | Meaning | Actionable? |
| --- | --- | --- |
| `PROTECTED` | Never touched | no |
| `CACHE-SAFE` | Regenerable; the owner rebuilds it on demand | **yes** |
| `ORPHAN?` | No inventory source claims it, and it's stale | **yes** |
| `REVIEW` | Ambiguous, or holds user-data-shaped files | only with `--allow-review` |
| `UNKNOWN` | Insufficient evidence | no |

"Actionable" means `bleach plan` will include it by default and the TUI will
let you select it. Everything else is reported for context.

## PROTECTED

Hard protections, any one of which is sufficient:

- **A live process** is executing from the path. Deleting a running app's state
  is the most damaging thing this tool could do, so this is re-checked at apply
  time too.
- **A protected path substring** — `CloudDocs`, `Mobile Documents`,
  `MobileSync` (iOS device backups: huge and irreplaceable), `Keychains`,
  `Mail`, `Messages`, `AddressBook`, `CallHistory`, `Photos`, `FileProvider`,
  and more.
- **A protected name** — `.ssh`, `.gnupg`, `.aws`, `.kube`, `.docker`,
  `.password-store`, `.netrc`, `.Trash`. These are small enough that bleach
  would never propose them on size grounds anyway, but "would never propose" is
  not a safety guarantee and being explicit is.
- **A protected bundle prefix** — `com.apple.*`, `group.com.apple.*`.
- **A registered `.app` bundle inside** — the self-updater case.
- **A UUID-named sandbox container.** Their metadata plist is
  entitlement-protected and unreadable, so an owner can never be established.
  Unknowable means untouchable.

There is also a *soft* protection: **the owner is installed**. This is the
default verdict for an installed app's state, but unlike the above it can be
demoted by version retention — which is how a stale `IntelliJIdea2025.3`
becomes actionable while `2026.2` stays protected.

## CACHE-SAFE

Regenerable by definition. Safe for installed owners *and* orphans, because the
owner rebuilds it.

Matched either by scan-root kind (`Caches`, `Logs`, `Saved Application State`,
`HTTPStorages`, `WebKit`) or by name pattern:

```
-updater$          electron-updater download leftovers
^Cache$  Caches?$  ^Cached
Code Cache  GPUCache  GrShaderCache  ShaderCache  DawnCache
Crashpad  CrashReporter
^Service Worker$  ^logs?$  \.log$  ^tmp$  ^temp$
```

A cache that contains user-data-shaped files is demoted to `REVIEW` rather than
staying here.

## ORPHAN?

No inventory source claims the directory, it hasn't been touched inside the
stale window (180 days by default), and nothing in it looks like user data.

Also reached by **version retention**: a version-scoped directory of an
installed app, superseded by a newer sibling and stale, is an orphan even
though its owner is very much present.

The question mark is honest. This is the tier where bleach is making a
judgement call, and it's the one worth reading `--explain` output for.

## REVIEW

The interesting bucket, and deliberately non-actionable. A candidate lands here
when:

- it's unowned but **holds user-data-shaped files** — Slack's 1.1 GB container
  on the development machine, three years stale but full of message databases;
- it's unowned but **recently active** — something is still writing there, and
  bleach can't say what;
- its owner ships **its own cleanup command**, so bleach reports the size and
  the command instead of reimplementing a retention policy it doesn't
  understand:

  ```
  Delegate these — the tool knows its own retention policy:
    11.5G   Homebrew    brew cleanup --prune=all
     1.8G   pnpm        pnpm store prune
     2.8G   IntelliJ…   JetBrains Toolbox > settings > clear old caches
  ```

- it's a launchd job, where removal changes behaviour rather than reclaiming
  space.

`REVIEW` being large is honest, not a bug — on the development machine it holds
65 GB. It does need better subdivision; see [Limitations](/guide/limitations).

## UNKNOWN

The default. Insufficient evidence either way, or an actionable verdict on
something below `min_actionable_bytes` (10 MB), so a 40 KB orphan can't clutter
a plan.

Also where candidates land when they're superseded by finer-grained children,
or when a plugin's tier hint wasn't recognised — an unknown hint degrades to
report-only rather than to anything that acts.

## Why the asymmetry

A missed orphan costs disk space. A false positive costs irreplaceable data.
Those are not comparable, so the tiering is biased hard: ambiguity resolves
toward `REVIEW` and `UNKNOWN`, and the two actionable tiers require positive
evidence rather than merely the absence of contrary evidence.

## Filtering by tier

```sh
bleach scan --tier orphan       # orphan, orphan-likely, orphaned
bleach scan --tier cache-safe   # cache-safe, cache, safe
bleach scan --tier review
bleach scan --tier protected
bleach scan --tier unknown
```
