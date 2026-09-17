# Rules

Everything risky is data, not code: which paths must never be touched, which
directory belongs to which bundle ID, which names mark regenerable state.

```sh
bleach rules              # print the effective rules
bleach rules --init       # copy them to ~/.config/bleach/rules.yaml
```

## Overlays can only add protections

Your overlay is merged over the defaults with one deliberate asymmetry:

- **List entries are appended.** You cannot remove a shipped protection by
  overriding a list.
- **Scalars are replaced.** Thresholds are yours to set.
- **Maps are merged**, with your value winning on a key collision.

So an overlay can make bleach more careful but never less. If you genuinely
need to act on something the defaults protect, that's what `--allow-review`
and hand-editing a plan are for.

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
```

### `delegated_cleanups`

When a tool ships its own cleanup with its own retention policy, bleach reports
the size and prints the command rather than reimplementing a policy it doesn't
understand.

```yaml
delegated_cleanups:
  "Homebrew": "brew cleanup --prune=all"
  "pnpm": "pnpm store prune"
  ".npm": "npm cache clean --force"
  ".m2": "rm -rf ~/.m2/repository  (redownloaded by the next build)"
  ".gradle": "gradle --stop, then rm -rf ~/.gradle/caches"
  ".rustup": "rustup toolchain list, then rustup toolchain uninstall <old>"
```

Delegated entries land in `REVIEW`, so they're reported but never acted on.
This is the single highest-value section: on the development machine it
surfaced roughly **50 GB** of cleanup that the owning tools do correctly and
bleach would do badly.

Delegated entries are checked *before* the nested-app-bundle protection, so
`ms-playwright` — whose browser caches contain registered `.app` bundles but
are fully reinstallable — gets reported rather than silently protected.

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
