# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Tags and releases use bare version numbers, without a `v` prefix.

## [Unreleased]

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

[Unreleased]: https://github.com/emdzej/bleach/compare/0.1.1...HEAD
[0.1.1]: https://github.com/emdzej/bleach/compare/0.1.0...0.1.1
[0.1.0]: https://github.com/emdzej/bleach/releases/tag/0.1.0
