# bleach

[![CI](https://github.com/emdzej/bleach/actions/workflows/ci.yml/badge.svg)](https://github.com/emdzej/bleach/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/emdzej/bleach?sort=semver)](https://github.com/emdzej/bleach/releases/latest)
[![Docs](https://img.shields.io/badge/docs-bleach.emdzej.pl-3b7ea1)](https://bleach.emdzej.pl)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

Find and safely reclaim orphaned application state on macOS.

**📖 Full documentation: [bleach.emdzej.pl](https://bleach.emdzej.pl)**

`~/Library` accumulates directories belonging to apps you uninstalled months
ago, superseded versions of apps you still use, and caches nothing will ever
read again. On the machine this was developed against, that came to **128 GB**
across `~/Library` and the dotfile directories — of which ~15 GB was safely
reclaimable and another ~50 GB was delegatable to tools that ship their own
cleanup commands.

## Install

```sh
curl -fsSL https://github.com/emdzej/bleach/releases/latest/download/bleach-macos-universal.tar.gz \
  | tar xz
sudo mv bleach /usr/local/bin/

# unsigned build — clear the Gatekeeper attribute on first run
xattr -d com.apple.quarantine /usr/local/bin/bleach

bleach scan
```

Or from source (Swift 6.0+):

```sh
git clone https://github.com/emdzej/bleach.git && cd bleach
swift build -c release
cp .build/release/bleach /usr/local/bin/
```

Grant your terminal **Full Disk Access** (System Settings → Privacy &
Security), or large parts of `~/Library` are unreadable and every size is an
undercount. bleach tells you when this is happening rather than silently
reporting less. → [details](https://bleach.emdzej.pl/guide/full-disk-access)

## Use

```sh
bleach scan                         # read-only table, largest first
bleach scan --tier orphan --explain # just orphans, with the evidence trail
bleach scan --by-owner              # group one owner's state across all locations

bleach tui                          # browse, select, then plan or apply directly

bleach plan -o plan.json            # write a plan (CACHE-SAFE + ORPHAN? by default)
bleach apply plan.json              # dry run
bleach apply plan.json --yes        # move to quarantine

bleach restore <batch>              # put it all back
bleach quarantine --purge --all --yes   # commit, permanently
```

→ [Full CLI reference](https://bleach.emdzej.pl/guide/cli)

## The problem this actually solves

There is no link on disk from `~/Library/Application Support/Foo` back to an
app. "Is this an orphan?" cannot be computed — it can only be argued for from
evidence. So bleach gathers evidence from six independent sources, records why
it reached each conclusion, and sorts paths into tiers by how safe removal is.
You read the evidence; it never decides alone.

It also turns out orphaned apps are only part of the story. bleach handles four
distinct classes:

| Class | Example | How it's found |
|---|---|---|
| **Orphaned owner** — app is gone | `com.isaacmarovitz.Whisky`, 854 MB, untouched 20 months | no inventory source claims it |
| **Version orphans** — app installed, old version's state left behind | `IntelliJIdea2025.3` next to `2026.2` | version-stripped sibling detection |
| **Regenerable caches** | `Caches/lens-desktop-updater`, 1 GB | rules + owner-installed check |
| **Intra-app dead state** | 8 of 54 Claude Code session dirs whose projects were deleted | plugins |

→ [How it works](https://bleach.emdzej.pl/guide/how-it-works)

## Safety model

- **Scanning is read-only.** Always.
- **Reversible by default.** `apply` *renames* paths into
  `~/.local/state/bleach/quarantine` — an O(1) metadata operation on APFS, so
  10 GB moves instantly. `--mode trash` and `--mode delete` exist when you want
  them, and are held to identical validation.
- **Confined to `$HOME`.** Candidates outside your home are measured and
  reported but never plannable, enforced by three independent layers. bleach
  never asks for `sudo`.
- **The plan is a file you review.** Scanning emits JSON; you read and edit it;
  `apply` executes it and does no analysis of its own.
- **`apply` re-validates everything** against live state: existence, symlinks,
  current protection rules, running processes, and whether the directory grew
  since planning.
- **Asymmetric by design.** A missed orphan costs disk space; a false positive
  costs irreplaceable data. Ambiguity resolves toward `REVIEW`, which is
  non-actionable unless you opt in.

→ [Scope & safety](https://bleach.emdzej.pl/guide/scope) ·
[Disposal modes](https://bleach.emdzej.pl/guide/disposal-modes)

## Tiers

| Tier | Meaning |
|---|---|
| `PROTECTED` | Never touched. System-owned, live process, credentials, iCloud mirrors, or a self-updating app's real binary. |
| `CACHE-SAFE` | Regenerable. The owner rebuilds it on demand. |
| `ORPHAN?` | No inventory source claims it, and it's stale. Actionable, with confirmation. |
| `REVIEW` | Ambiguous, or holds user-data-shaped files. Reported; needs `--allow-review`. |
| `UNKNOWN` | Insufficient evidence. Reported, never acted on. |

→ [Tiers in detail](https://bleach.emdzej.pl/guide/tiers)

## Extending

**Rules** are YAML, not code — `bleach rules --init` writes a copy to
`~/.config/bleach/rules.yaml`. List entries in your overlay are *appended* to
the defaults, so an override can only ever add protections, never remove one.
→ [Rules](https://bleach.emdzej.pl/guide/rules)

**Plugins** are plain executables speaking JSON on stdio, so community
resolvers can contribute the risky domain knowledge — which directory belongs
to what, and which parts of it are dead — without touching the safety
machinery. A plugin proposes; it never acts, never escapes its declared scope,
and can never weaken a core protection.
→ [Writing a plugin](https://bleach.emdzej.pl/guide/plugins)

Two examples ship in [`plugins/`](plugins):

- **`claude-code-sessions`** — decodes `~/.claude/projects` directory names back
  into project paths and checks whether the project still exists. A session for
  a deleted checkout is unambiguously dead, which no mtime heuristic can tell
  you.
- **`opencode-sessions`** — splits `~/.local/share/opencode` (2.8 GB) by role:
  redownloadable language servers, per-session snapshots, session diffs, and the
  live database, which is deliberately never a candidate.

## Development

```sh
swift build
swift test          # 39 tests; SafetyTests, PluginSecurityTests and
                    # RemovalModeTests cover the invariants that must never regress

npm install         # docs site
npm run docs:dev
```

Pipeline: `scan` (measure) → `resolve` (attribute) → `classify` (tier) →
`plan` (emit artifact) → `apply` (execute, re-validating).

Known limitations are documented honestly:
→ [Limitations](https://bleach.emdzej.pl/guide/limitations)

## License

MIT — see [LICENSE](LICENSE).

Built by [emdzej.pl](https://emdzej.pl).
