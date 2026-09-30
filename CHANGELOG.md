# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Tags and releases use bare version numbers, without a `v` prefix.

## [Unreleased]

## [0.3.0] — 2026-09-30

Coverage. `~/Library` is scanned at named subdirectories rather than wholesale,
which is deliberate — `Mail`, `Messages` and `Keychains` are siblings of the
rest — but it means anything absent from that list was invisible however large
it grew. Two things were, and reaching them turned up two ordering bugs that
had kept curated cleanup advice from ever being shown.

On the machine this was measured against, 15.3 GB moved out of `PROTECTED`
into something actionable or advisory.

One behaviour change to know about when upgrading: some paths that previously
read `PROTECTED` now read `REVIEW` and carry the owning tool's cleanup command.
`REVIEW` is still non-actionable without `--allow-review`, so nothing became
deletable — but rows that used to be unselectable in the TUI now are.

### Added

- **`~/Library/Developer` is now scanned.** 8.5 GB on the machine this was
  added against, none of it previously visible: `~/Library` is scanned at
  named subdirectories rather than wholesale, so anything absent from that
  list was invisible regardless of size. Descends one level into `Xcode` and
  `CoreSimulator`, because their children have wildly different reconstruction
  costs and must not share a verdict:
  - `iOS DeviceSupport` (and the watchOS/tvOS variants) is regenerable — 5.3 GB
    of device symbols, re-extracted on the next attach. The single largest win.
  - `DerivedData` is delegated with the plain `rm -rf` remedy.
  - `CoreSimulator/*` delegates to `xcrun simctl delete unavailable`, which
    removes only devices whose runtime is already gone.
  - `Xcode/Archives` and `Xcode/UserData` are protected: shipped builds with
    their dSYMs, and hand-made key bindings, themes and breakpoints.
- **`~/Library/pnpm` is now scanned** — 5.4 GB. pnpm's store lives here on
  macOS rather than under `~/.cache`, so the shipped `pnpm store prune`
  delegation had no candidate to attach to.
- `regenerable_despite_bundle_prefix`, a deliberately tiny rules list for
  state that is regenerable even though its owner's bundle prefix is
  protected. One entry: Squirrel.Mac's `<bundle-id>.ShipIt` update staging
  directory.

### Fixed

- **Delegated cleanups were unreachable for anything with a protected bundle
  prefix.** The prefix heuristic ran first, so the shipped
  `com.apple.dt.Xcode` entry had never once fired, and
  `~/Library/Developer/CoreSimulator/Devices` was hard-protected because the
  resolver name-matched the generic leaf `Devices` to Spotlight's
  `com.apple.dt.Devices`. Delegation is now consulted before the prefix
  heuristic. This cannot make anything deletable — delegation yields
  non-actionable `REVIEW` — and the explicit data protections (live process,
  protected path, protected name) still run ahead of it.
- **1.4 GB of stale VS Code installer payload was permanently protected.**
  `com.microsoft.VSCodeInsiders.ShipIt` inherited the `com.microsoft.VSCode`
  prefix, which is protected because workspace state is not reconstructible —
  a reason that does not apply to a downloaded update. Now `CACHE-SAFE`, with
  the bypass recorded in the evidence trail.
- `ScanRoot.enumerateChildren` was declared, documented, and never read, so a
  root could only ever be a container of candidates rather than one itself.
  That is what `~/Library/pnpm` needs, since `store` and `global` are
  meaningless alone and match no cleanup rule.

## [0.2.0] — 2026-09-25

A correctness and safety release: the findings from a full audit of the
codebase. Every item below was reproduced with a test before being fixed, and
each has a regression test. The suite grew from 39 to 73 tests.

Two behaviour changes to know about when upgrading:

- **Plugins are no longer discovered in the working directory.** If you were
  relying on `./plugins/` being picked up from a checkout, use
  `BLEACH_PLUGIN_PATH=./plugins` instead.
- **`apply --dry-run` now wins over `--yes`.** Previously the flag was
  ignored, so passing both moved files.

### Fixed

- **`quarantine --purge` could delete directories outside the quarantine.**
  A batch's `id` was read from its `manifest.json` and interpolated into the
  path passed to `removeItem`, guarded only by a `hasPrefix` string check that
  `..` segments pass straight through. A batch is now identified by its
  directory name, which must be a single ordinary path component. This was the
  only irreversible code path in the tool.
- **`restore` validated nothing.** `originalPath` and `storedName` were taken
  from the manifest and used directly as move destinations and sources, so a
  hand-edited or corrupted manifest could write anywhere the user could write.
  Both are now validated, sharing the same path-shape checks as `apply`.
- **A plugin's tier hint could overrule a core verdict.** The hint was applied
  unconditionally unless a path was `hardProtected`, which marks only the five
  tier-0 rules — so a hint could promote `REVIEW` ("holds user-data-shaped
  files") or a soft `PROTECTED` ("owner is installed") straight to
  `CACHE-SAFE` and into a plan. A hint can now only sharpen `UNKNOWN` or make
  a verdict more protective; disagreements are recorded in the evidence trail.
- **Plugins were discovered in the working directory.** `./plugins/` was
  searched relative to wherever bleach was invoked, so running a scan inside a
  repository that ships a `plugins/` directory executed its contents. Removed;
  use `BLEACH_PLUGIN_PATH` to opt in. Added `--no-plugins` to skip discovery.
- **A symlinked parent directory escaped the home-directory confinement.**
  The check was lexical and the symlink test covered the leaf only, so with
  `~/Library/Caches` relocated to another volume — a routine disk-space move
  on the highest-traffic scan root — `apply` would act on paths outside the
  home. Confinement is now confirmed against fully resolved paths, at both the
  plan and the plugin boundary.
- **A partial `rules.yaml` overlay failed to load.** Swift's synthesised
  `Decodable` ignores property defaults, so an overlay threw `keyNotFound` on
  the first key it did not contain — including the worked example in the
  documentation. Overlays now need only the keys you care about, a
  comments-only file is treated as no overlay, and a threshold set to the same
  value as the default is no longer silently ignored.
- **bleach could plan the removal of its own quarantine.** `~/.local/state`
  is a scan root, so a quarantine untouched for `stale_days` classified as
  `ORPHAN?` and became plannable; `--mode delete` would then destroy the undo
  history for everything bleach had ever moved. Now excluded from scanning and
  protected by default.
- **`apply --dry-run` did nothing.** The flag was declared and never read, so
  `--dry-run --yes` moved files. `--dry-run` now wins over `--yes`.
- **A path flattening to `manifest.json` overwrote its own batch manifest.**
  `~/manifest.json` stored as exactly that name, and the manifest write then
  clobbered it: the file was lost and the batch record corrupted. The name is
  now reserved.
- **A failed manifest write left a batch unrestorable.** The manifest was
  written only after every rename, so a failure stranded the files with no
  record. A skeleton manifest is now written before the first move, and the
  journal is written before the manifest rewrite.
- **Version retention could promote a `REVIEW` verdict to actionable.**
  Retention demoted anything not `hardProtected`, which included deliberate
  "a human needs to look at this" verdicts — delegated cleanups and launchd
  jobs. It now only demotes the verdicts it is meant to.
- **`--min-size` silently meant "no minimum" on unreadable input.**
  `--min-size 100MB` parsed as `0` and *widened* a plan to everything instead
  of narrowing it. Unreadable values are now a usage error, `2GB` is accepted,
  and the value is parsed before the scan starts rather than after.
- **Journal write failures were swallowed.** In `delete` mode the journal is
  the only surviving record of what was removed, so a failure is now reported.
  The journal is also opened `O_APPEND`, so concurrent runs cannot interleave
  a line.
- `quarantine --purge` reported the size it previewed rather than the size it
  actually freed.
- `tui --allow-review` described itself as gating row *selection*; it gates
  apply-time validation. Rows could always be selected.

### Added

- `--no-plugins` on `scan`, `tui`, and `plan`.
- CI now exercises `plan` → `apply` → `restore` → `purge` end to end, plus a
  partial rules overlay and `--min-size` validation.

## [0.1.1] — 2026-09-17

Packaging only. The binary is functionally identical to 0.1.0.

### Changed

- Releases now ship three builds — `arm64`, `x86_64` and `universal` — instead
  of universal alone, so a typical download is a third of the previous size.
- Release binaries are stripped of local and debug symbols, which roughly
  halves each one. Exported symbols are retained, so crash backtraces still
  symbolise.
- Assets no longer carry a version in the filename. It was redundant:
  `releases/download/<tag>/<name>` already pins a version, and
  `releases/latest/download/<name>` needs the name to be stable.
- Install instructions use `uname -m` to pick the matching slice.
- Tarballs now include `CHANGELOG.md`.

Download sizes, compressed:

| Asset | 0.1.0 | 0.1.1 |
|---|---|---|
| arm64 | — | 0.78 MB |
| x86_64 | — | 0.83 MB |
| universal | 2.30 MB | 1.61 MB |

## [0.1.0] — 2026-09-17

First release.

### Added

#### Scanning

- `bleach scan` — read-only measurement and tiering of `~/Library`, the XDG
  directories (`~/.cache`, `~/.local/share`, `~/.local/state`) and dot-directories
  in `~`. Output sorted by size, with `--tier`, `--min-size`, `--limit`,
  `--by-owner`, `--explain`, `--json` and `--quiet`.
- Owner attribution from six independent inventory sources, each weighted by how
  strongly it implies the owner is currently installed: running processes (1.00),
  filesystem walk and Spotlight (0.95), Homebrew Caskroom/Cellar (0.90), launchd
  agents and daemons (0.70), the LaunchServices registry (0.60), and installer
  receipts (0.25).
- Resolution strategies tried in order: alias table, name-is-a-bundle-ID, App
  Group team-ID prefix, canonical name match, and version-stripped stem match.
- Corroborating signals independent of the name: newest internal mtime,
  `Preferences` plist, saved application state, launchd job liveness, the
  cross-location sibling set, and detection of a registered `.app` bundle inside
  a candidate.
- Five tiers — `PROTECTED`, `CACHE-SAFE`, `ORPHAN?`, `REVIEW`, `UNKNOWN` — assigned
  most-protective-first, with score used only as a tiebreak within a tier.
- Version retention: among candidates reducing to the same stem, the newest is
  kept and the rest marked superseded. Only demotes *soft* protections, so
  "its owner is installed" can be overridden but "a process is running here"
  cannot.
- Overlap detection: a candidate containing other candidates is excluded from
  totals and from every actionable tier, so no byte is counted twice.
- Delegated cleanups — when a tool ships its own cleanup with its own retention
  policy, bleach reports the size and the command rather than reimplementing it.
- System roots (`/Library/{Application Support,Caches,Logs}`) are measured and
  reported with full evidence but never actionable, since acting would need root.

#### Interactive

- `bleach tui` — full-screen browser with the evidence trail for the selected
  row, tier filtering, search, and per-row selection. Hand-rolled ANSI/termios,
  no dependencies.
- Apply directly from the TUI via a confirmation modal that states the disposal
  mode and its consequence before accepting input. The irreversible mode requires
  typing `delete` in full.
- Terminal state is restored on every exit path, including `SIGINT`, `SIGTERM`
  and `SIGHUP`.

#### Plans and disposal

- `bleach plan` — writes a reviewable JSON plan. `CACHE-SAFE` and `ORPHAN?` by
  default; other tiers must be requested. Paths outside `$HOME` are never
  included.
- `bleach apply` — dry run by default. Re-derives every safety property from
  scratch rather than trusting the plan: path shape and standardisation,
  `$HOME` containment, existence, symlinks, current protection rules, running
  processes, nested app bundles, tier actionability, growth since planning, and
  read completeness. Validation runs again immediately before each disposal.
- Three disposal modes, all held to identical validation: `quarantine` (default,
  an O(1) APFS rename into `~/.local/state/bleach/quarantine`), `trash`
  (Finder's Trash), and `delete` (irreversible).
- `bleach restore` — restores a batch or individual paths. Never overwrites a
  recreated destination.
- `bleach quarantine` — lists batches; `--purge` with `--older-than` or `--all`
  commits them permanently.
- Append-only journal at `~/.local/state/bleach/journal.jsonl`, written for every
  mode including `delete`.

#### Configuration and extension

- `bleach rules` — prints the effective rules; `--init` writes an overlay to
  `~/.config/bleach/rules.yaml`. List entries in an overlay are appended to the
  defaults, so an override can only ever add protections, never remove one.
- Plugin protocol v1 — plain executables speaking JSON on stdio, with
  `manifest`, `enumerate` and `resolve` modes. Plugins propose candidates and
  evidence; they cannot act, cannot escape their declared `owns` scope, cannot
  weaken a core protection, and have their evidence weights clamped to ±10.
- Example plugin `claude-code-sessions` — decodes `~/.claude/projects` directory
  names back into project paths and reports sessions whose project no longer
  exists.
- Example plugin `opencode-sessions` — splits `~/.local/share/opencode` by role,
  deliberately never proposing the live database as a candidate.

#### Project

- Documentation site at [bleach.emdzej.pl](https://bleach.emdzej.pl).
- 39 tests, with `SafetyTests`, `PluginSecurityTests` and `RemovalModeTests`
  covering the invariants that must not regress.
- CI builds and tests on macOS; tagged releases publish a universal
  (`arm64` + `x86_64`) binary with checksums.

### Known limitations

- No size cache, so a full scan re-walks everything and takes about a minute.
- `REVIEW` is a large, under-subdivided bucket.
- The alias table is small by design — only entries verified against a real
  LaunchServices registry are shipped, since a wrong alias mis-attributes a
  directory silently.
- UUID-named sandbox containers can never be attributed, as their metadata is
  entitlement-protected, so they are permanently protected.
- Release binaries are unsigned and unnotarised; Gatekeeper blocks the first run
  until the quarantine attribute is cleared.
- Untested below macOS 13.

[Unreleased]: https://github.com/emdzej/bleach/compare/0.3.0...HEAD
[0.3.0]: https://github.com/emdzej/bleach/compare/0.2.0...0.3.0
[0.2.0]: https://github.com/emdzej/bleach/compare/0.1.1...0.2.0
[0.1.1]: https://github.com/emdzej/bleach/compare/0.1.0...0.1.1
[0.1.0]: https://github.com/emdzej/bleach/releases/tag/0.1.0
