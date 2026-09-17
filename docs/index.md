---
layout: home

hero:
  name: bleach
  text: Reclaim orphaned app state on macOS
  tagline: >-
    ~/Library fills up with directories belonging to apps you uninstalled
    months ago. bleach finds them, shows you why it thinks so, and moves them
    somewhere you can get them back from.
  actions:
    - theme: brand
      text: Get started
      link: /guide/getting-started
    - theme: alt
      text: How it works
      link: /guide/how-it-works
    - theme: alt
      text: GitHub
      link: https://github.com/emdzej/bleach

features:
  - title: Evidence, not guesses
    details: >-
      Nothing on disk links ~/Library/Application Support/Foo back to an app.
      bleach gathers evidence from six independent sources and shows you the
      reasoning behind every verdict.
    link: /guide/how-it-works
    linkText: What it checks

  - title: Reversible by default
    details: >-
      apply renames paths into a quarantine — an O(1) metadata operation on
      APFS, so 10 GB moves instantly. Trash and permanent delete are there
      when you want them, held to identical validation.
    link: /guide/disposal-modes
    linkText: Disposal modes

  - title: Confined to your home
    details: >-
      Candidates outside $HOME are measured and reported but never actionable.
      bleach never asks for sudo, and three independent layers enforce it.
    link: /guide/scope
    linkText: Scope & safety

  - title: Extensible
    details: >-
      Rules are YAML, not code. Resolvers are plain executables speaking JSON
      on stdio — a 40-line script is a complete plugin, and it can never
      weaken a protection.
    link: /guide/plugins
    linkText: Write a plugin
---

## What it found on one real machine

A single scan of the development machine — 128 GB measured across `~/Library`
and the dotfile directories:

```
CACHE-SAFE 12.8G (47)   ORPHAN? 2.3G (22)   REVIEW 65.4G (343)   PROTECTED 50.3G (2786)

TIER       SIZE   AGE    WHERE            NAME                        OWNER
ORPHAN?     854M  20mo   app-support      com.isaacmarovitz.Whisky    —
ORPHAN?     286M  6mo    app-support      dev.warp.Warp-Stable        —
ORPHAN?     176M  6mo    dotdirs          .kiro                       —
ORPHAN?     152M  19mo   dotdirs          .azuredatastudio            —
ORPHAN?     122M  2y     app-support      com.wondershare.Installer   —
```

Every one of those five was verified genuinely uninstalled. But orphans turned
out to be only part of the story — the tool also found **~50 GB** belonging to
tools that ship their own cleanup commands, and reports those rather than
reimplementing their retention policy:

```
Delegate these — the tool knows its own retention policy:
  11.5G   Homebrew           brew cleanup --prune=all
   8.0G   .espressif         reinstall via the ESP-IDF installer when next needed
   3.6G   .m2                rm -rf ~/.m2/repository
   1.8G   pnpm               pnpm store prune
```

## Four kinds of dead weight

Orphaned apps are the obvious case. They are not the biggest one.

| Class | Example | How it's found |
| --- | --- | --- |
| **Orphaned owner** — the app is gone | Whisky, 854 MB, untouched 20 months | no inventory source claims it |
| **Version orphans** — app installed, old version's state abandoned | `IntelliJIdea2025.3` beside `2026.2` | version-stripped sibling detection |
| **Regenerable caches** | `Caches/lens-desktop-updater`, 1 GB | rules plus an owner-installed check |
| **Intra-app dead state** | 8 of 54 Claude Code session directories whose projects were deleted | [plugins](/guide/plugins) |

That last row is worth dwelling on. The bundled `claude-code-sessions` plugin
decodes session directory names back into project paths and checks whether the
project still exists on disk. "The project this belongs to was deleted" is
categorical; "untouched for 200 days" is merely circumstantial.

## Install

```sh
# Download the latest release
curl -fsSL https://github.com/emdzej/bleach/releases/latest/download/bleach-macos-universal.tar.gz \
  | tar xz
sudo mv bleach /usr/local/bin/

bleach scan
```

Or build from source:

```sh
git clone https://github.com/emdzej/bleach.git && cd bleach
swift build -c release
cp .build/release/bleach /usr/local/bin/
```

Scanning is always read-only. See [Getting started](/guide/getting-started).
