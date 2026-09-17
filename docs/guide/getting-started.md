# Install & first scan

## Install

### From a release

```sh
curl -fsSL https://github.com/emdzej/bleach/releases/latest/download/bleach-macos-universal.tar.gz \
  | tar xz
sudo mv bleach /usr/local/bin/
```

Release binaries are universal (`arm64` + `x86_64`) and built by GitHub
Actions. Tags and releases use bare version numbers, without a `v` prefix; see
the [changelog](https://github.com/emdzej/bleach/blob/main/CHANGELOG.md). Each
release also carries a `.sha256` you can verify:

```sh
shasum -a 256 -c bleach-macos-universal.tar.gz.sha256
```

The binaries are unsigned, so the first run may be blocked by Gatekeeper.
Either clear the quarantine attribute:

```sh
xattr -d com.apple.quarantine /usr/local/bin/bleach
```

…or build from source, which avoids the issue entirely.

### From source

Requires Swift 6.0 or newer (Xcode 16+).

```sh
git clone https://github.com/emdzej/bleach.git && cd bleach
swift build -c release
cp .build/release/bleach /usr/local/bin/
```

## First scan

```sh
bleach scan
```

This is **read-only**. It measures `~/Library` and your dotfile directories,
attributes each directory to an owner, and prints a table sorted by size.

Expect it to take around a minute on a full disk — most of that is walking
~130 GB to compute true sizes. There is no size cache yet.

```
  bleach  ·  985 owners (612 with bundle IDs), 39 launchd jobs, 998 live processes
  scanned 4146 paths,  128G total, 53.6s

  CACHE-SAFE 12.8G (47)   ORPHAN? 2.3G (22)   REVIEW 65.4G (343)   PROTECTED 50.3G (2786)

  TIER       SIZE   AGE    WHERE            NAME                       OWNER
  ORPHAN?     854M  20mo   app-support      com.isaacmarovitz.Whisky   —
  ORPHAN?     286M  6mo    app-support      dev.warp.Warp-Stable       —
```

Before you act on any of it, [grant Full Disk Access](/guide/full-disk-access)
— otherwise large parts of `~/Library` are unreadable and every size is an
undercount.

## Narrow it down

```sh
bleach scan --tier orphan              # just the suspected orphans
bleach scan --tier orphan --explain    # …with the evidence behind each verdict
bleach scan --min-size 100M            # ignore the noise
bleach scan --by-owner                 # group one owner's state across all locations
bleach scan --json                     # machine-readable
```

`--explain` is the one worth learning first. It prints the reasoning:

```
  ORPHAN?     854M  20mo   app-support   com.isaacmarovitz.Whisky
      clean noOwnerFound: com.isaacmarovitz.Whisky looks like a bundle ID
            but no installed app claims it
      clean stale: nothing modified inside for 617 days
      info  cacheRule: tiered ORPHAN?: no owner and stale
```

`--by-owner` is the one that shows you the real payoff, because a single app
scatters state across Application Support, Caches, Containers, Preferences,
HTTPStorages and more. Deleting the whole set is what reclaims meaningful
space.

## Then what

Two routes. Both are safe; pick whichever you prefer.

**Interactive** — browse, select rows, apply or write a plan:

```sh
bleach tui
```

**Scripted** — write a plan, read it, apply it:

```sh
bleach plan -o plan.json     # read-only; writes JSON
less plan.json               # actually read it
bleach apply plan.json       # dry run
bleach apply plan.json --yes # move to quarantine
```

Nothing is destroyed either way: `apply` defaults to a
[quarantine](/guide/quarantine) you can restore from.

## Next steps

- [How it works](/guide/how-it-works) — what evidence bleach gathers
- [Tiers](/guide/tiers) — what CACHE-SAFE and ORPHAN? actually mean
- [The TUI](/guide/tui) — keybindings and the confirmation flow
