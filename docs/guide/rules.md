# Rules

Everything risky is data, not code: which paths must never be touched, which
directory belongs to which bundle ID, which names mark regenerable state.

```sh
bleach rules              # print the effective rules
bleach rules --init       # copy them to ~/.config/bleach/rules.yaml
```

## How an overlay merges

Write only the keys you care about — an overlay is a handful of lines, not a
copy of the defaults.

- **List entries are appended.** You cannot remove a shipped protection by
  overriding a list, so the three `protected_*` lists can only ever grow.
- **Scalars are replaced.** Thresholds are yours to set.
- **Maps are merged**, with your value winning on a key collision.

So no overlay can delete a protection. It *can* still make bleach more
aggressive in the other direction, and this is deliberate: entries you add to
`regenerable_patterns` add new ways for a path to be judged safe to clear, and
lowering `min_actionable_bytes` or `stale_days` widens what gets proposed. The
file is your configuration and is trusted as such — but it is worth
re-reading the diff before a `--mode delete`.

If you need to act on something the defaults protect, that's what
`--allow-review` and hand-editing a plan are for.

## Sections

### `protected_bundle_prefixes`

Bundle-ID prefixes that are always protected.

```yaml
protected_bundle_prefixes:
  - com.apple.
  - group.com.apple.
  - com.microsoft.VSCode   # workspace state is not reconstructible
```

### `protected_path_contains`

Case-insensitive substrings that force `PROTECTED` anywhere in the path.

```yaml
protected_path_contains:
  - CloudDocs
  - Mobile Documents
  - MobileSync            # iOS device backups: huge and irreplaceable
  - Keychains
  - /Mail/
  - /Messages/
  - CallHistory
  - FileProvider
```

### `protected_names`

Exact leaf names, always protected. Credentials and key material live here.

```yaml
protected_names:
  - .ssh
  - .gnupg
  - .aws
  - .kube
  - .docker
  - .password-store
  - .netrc
  - .Trash
```

These are small enough that bleach would never propose them on size grounds
anyway — but "would never propose" is not a safety guarantee, and being
explicit is.

### `aliases`

Directory name → bundle identifier, for names that normalisation and fuzzy
matching can't bridge.

```yaml
aliases:
  "Code - Insiders": com.microsoft.VSCodeInsiders
  "Claude": com.anthropic.claudefordesktop
  "Freelens": app.freelens.Freelens
  "BambuStudio": com.bambulab.bambu-studio
  "Steam": com.valvesoftware.steam
```

The shipped table is small on purpose. Every entry in it was verified against
a real LaunchServices registry rather than guessed, because **a wrong alias
silently mis-attributes a directory**, which is worse than leaving it
unresolved.

To find the right identifier for something on your machine:

```sh
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/\
LaunchServices.framework/Support/lsregister -dump \
  | grep -B8 'identifier:.*yourapp'
```

### `regenerable_patterns`

Case-insensitive regexes on the candidate name marking state that is safe to
clear even when the owner is installed and running.

```yaml
regenerable_patterns:
  - "-updater$"            # electron-updater download leftovers
  - "^Cache$"
  - "Caches?$"
  - "^Cached"
  - "GPUCache"
  - "ShaderCache"
  - "Crashpad"
  - "\\.log$"
  - "DeviceSupport$"        # Xcode device symbols, re-extracted on attach
```

### `regenerable_despite_bundle_prefix`

The one list that can step around a tier-0 protection, so it is deliberately
tiny and every entry has to earn its place.

An updater's staging directory inherits its vendor's bundle identifier without
inheriting the reason that vendor is protected. Squirrel.Mac stages a
downloaded update in `<bundle-id>.ShipIt`: VS Code's *workspace state* is not
reconstructible, which is why `com.microsoft.VSCode` is a protected prefix, but
its downloaded installer is re-fetched on the next update check. Without this,
1.4 GB of stale payload sat permanently in `PROTECTED` and was never proposed.

```yaml
regenerable_despite_bundle_prefix:
  - "\\.ShipIt$"
```

Only the bundle-prefix heuristic is bypassed. A protected path, a protected
name, a live process, or a registered `.app` bundle living inside all still
win, and entries here count as `regenerable_patterns` in their own right.

### `delegated_cleanups`

When a tool ships its own cleanup with its own retention policy, bleach reports
the size and prints the command rather than reimplementing a policy it doesn't
understand.

```yaml
delegated_cleanups:
  "Homebrew": "brew cleanup --prune=all"
  "pnpm": "pnpm store prune"
  "CoreSimulator": "xcrun simctl delete unavailable"
  "DerivedData": "rm -rf ~/Library/Developer/Xcode/DerivedData  (Xcode rebuilds indexes)"
  ".npm": "npm cache clean --force"
  ".m2": "rm -rf ~/.m2/repository  (redownloaded by the next build)"
  ".gradle": "gradle --stop, then rm -rf ~/.gradle/caches"
  ".rustup": "rustup toolchain list, then rustup toolchain uninstall <old>"
```

Delegated entries land in `REVIEW`, so they're reported but never acted on.
This is the single highest-value section: on the development machine it
surfaced roughly **50 GB** of cleanup that the owning tools do correctly and
bleach would do badly.

Keys match either the candidate's leaf name or the first component of its
path-relative name, so `"CoreSimulator"` covers every child of
`~/Library/Developer/CoreSimulator`.

Delegated entries are checked *before* the nested-app-bundle protection, so
`ms-playwright` — whose browser caches contain registered `.app` bundles but
are fully reinstallable — gets reported rather than silently protected. The
same applies to `DerivedData`, which holds a registered `.app` for any build
you have launched.

They are also checked before the protected-bundle-prefix heuristic. A
delegated entry is curated knowledge about a specific directory, while a bundle
prefix fires on whatever the resolver guessed the owner to be — and generic
names guess wrong. `CoreSimulator/Devices` name-matched Apple's
`com.apple.dt.Devices` and inherited the blanket `com.apple.` protection, which
also left the shipped `com.apple.dt.Xcode` entry unreachable. Since delegation
yields non-actionable `REVIEW`, the ordering can only ever turn a blunt
protection into useful advice.

### Thresholds

```yaml
stale_days: 180            # no internal modification for this long = stale
keep_versions: 1           # versioned siblings to keep when the owner is installed
min_actionable_bytes: 10485760   # 10 MB; smaller candidates are reported, never proposed
```

`min_actionable_bytes` keeps a 40 KB orphan out of your plan. `keep_versions: 2`
is reasonable if you occasionally roll back an IDE.

## A worked overlay

```yaml
# ~/.config/bleach/rules.yaml

# Never touch my scratch dirs, whatever bleach thinks.
protected_names:
  - .experiments
  - .localstack

protected_path_contains:
  - /ClientWork/

# My in-house tool's bundle ID isn't discoverable from its directory name.
aliases:
  "AcmeDesigner": com.acme.designer

# Our build tool's scratch space is always safe to clear.
regenerable_patterns:
  - "^acme-build-"

# Bazel knows its own retention policy far better than bleach does.
delegated_cleanups:
  ".cache/bazel": "bazel clean --expunge"

# I want a shorter staleness window and two IDE versions kept.
stale_days: 90
keep_versions: 2
```

Verify it loaded:

```sh
bleach rules | head -40
bleach scan --rules ~/.config/bleach/rules.yaml --tier orphan
```

`--rules` takes an explicit path, which is handy for testing an overlay without
installing it.
