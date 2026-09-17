# Scope & safety

## What bleach reads vs. what it acts on

| | Read | Acted on |
| --- | --- | --- |
| `~/Library` (11 roots), `~/.cache`, `~/.local/{share,state}`, `~` dotdirs | yes | **yes** |
| `/Library/{Application Support,Caches,Logs}` | yes | **never** |
| `/Applications`, `/System/Applications`, `/var/db/receipts`, `/opt/homebrew`, `/usr/local`, `/Library/Launch*`, `lsregister`, `ps` | for attribution only | never candidates |

So *"is Slack installed?"* is answered machine-wide, while *"may I move
this?"* is answered home-only.

## Scan roots

Under `~/Library`: `Application Support`, `Caches`, `Containers`,
`Group Containers`, `HTTPStorages`, `WebKit`, `Saved Application State`,
`Logs`, `Preferences`, `Application Scripts`, `LaunchAgents`.

Outside it: `~/.cache`, `~/.local/share`, `~/.local/state`, and dot-directories
directly in `~`.

That last group matters more than it sounds. On the development machine,
opencode alone held **2.8 GB in `~/.local/share`** — completely invisible to a
Library-only scan. Tooling installed outside the app-bundle world keeps state
in XDG-ish directories, and it is not small.

`.cache`, `.local`, `.config` and `.Trash` are excluded from the dotdir root
because they are separate roots or protected outright — otherwise their
contents would be counted twice.

### Umbrella directories

Some vendors shard state by product and version under one directory:
`JetBrains`, `Google`, `Adobe`, `Microsoft`, `Mozilla`, `Steam`, `Chromium`,
`Code - Insiders` and others. bleach descends one extra level into these, so
`JetBrains/IntelliJIdea2025.3` becomes its own candidate instead of hiding
inside a single 5 GB blob.

## The `$HOME` boundary

Three independent layers enforce it:

1. **Scan roots** outside `$HOME` carry a `requiresRoot` flag, which excludes
   them from plans and from TUI selection.
2. **`ApplyValidator`** refuses any path not prefixed with `$HOME/`, and
   refuses `$HOME` itself.
3. **`PluginHost`** applies the same check to everything a plugin returns.

bleach never asks for `sudo` and cannot act outside your home even if a
hand-edited plan tells it to. This is covered by `SafetyTests`, which asserts
that `/etc/hosts` and `/tmp` are refused.

## System-level state

`/Library` is scanned and reported with full evidence, so your reclaimable
total is honest, but nothing there is ever plannable:

```
  Outside your home — needs sudo, bleach will not touch these:  900M
     529M   ORPHAN?    /Library/Application Support/Autodesk/AcActivityInsights
     197M   ORPHAN?    /Library/Application Support/Microsoft/TeamsUpdaterDaemon
      80M   ORPHAN?    /Library/Application Support/Autodesk/AdpDesktopSDK
      46M   CACHE-SAFE /Library/Logs/DiagnosticReports
    sizes are undercounts without root; verify before removing
```

Those rows appear in the TUI marked `⚿` and cannot be selected.

This is a deliberate line. A tool that can `rm -rf` in `/Library` as root is a
categorically different risk from one confined to `$HOME`: the blast radius
includes other users' data and `/System` adjacency. So bleach tells you what's
there and hands you the command; you stay the one holding the root shell.

Sizes in that section are undercounts without root, and the report says so
rather than implying precision it doesn't have.

## Plugin boundary

Plugins **propose**; they never act. A plugin cannot delete, move, or write
anything, never receives file contents, and can only speak about paths inside
the scope it declared. It cannot weaken a core protection — if bleach
hard-protects a path, a plugin asking for its removal is recorded and ignored.
Evidence weights are clamped to ±10 so a plugin can't swamp core scoring.

See [Writing a plugin](/guide/plugins).

## What could still go wrong

Being straight about the residual risk:

- **A wrong alias** would mis-attribute a directory. This is why the shipped
  alias table is small and was verified against a real LaunchServices registry
  rather than guessed — an unresolved directory is safer than a
  confidently-mislabelled one.
- **Heuristic staleness.** A directory untouched for 200 days might still
  matter. That's why staleness alone never produces an actionable verdict; it
  has to combine with "no owner found".
- **Undercounted sizes** without Full Disk Access can hide a large orphan below
  a `--min-size` filter. `apply` refuses partially-unreadable paths for this
  reason.
- **User data in an unowned directory.** The user-data heuristic looks at file
  extensions and names, and it can miss a bespoke format. This is the main
  argument for leaving the default quarantine mode alone rather than reaching
  for `--mode delete`.
