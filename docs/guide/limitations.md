# Limitations

Being straight about what this tool doesn't do well yet.

## Scans are slow

A full scan takes roughly a minute, because it walks ~130 GB to compute true
allocated sizes. There is no size cache — every run re-walks everything.

`--fast-inventory` skips the `lsregister -dump` (about 4.5 s) but not the walk,
so it helps far less than the name suggests.

A cache keyed on directory mtime would fix this, and is the most obvious next
improvement.

## REVIEW is a very large bucket

On the development machine, `REVIEW` holds 65 GB across 343 paths. That's the
honest answer for genuinely ambiguous state, but a bucket that large is not
actionable — it needs subdividing by *why* a candidate landed there:

- delegated to another tool's cleanup
- unowned but holds user-data-shaped files
- unowned but recently active
- a launchd job

Those are four very different situations currently rendered identically.

## The alias table is small

Only entries verified against a real LaunchServices registry are shipped.
That's the right trade — a wrong alias silently mis-attributes a directory,
which is worse than leaving it unresolved — but it means many human-named
directories resolve to nothing on a machine with unusual software.

Contributions are welcome, ideally with the `lsregister` output that verifies
them. See [Rules](/guide/rules).

## System state is reported, never actioned

`/Library/{Application Support,Caches,Logs}` are scanned but nothing there is
plannable, because acting would need root. Sizes in that section are
undercounts without root, and the report says so.

This is a deliberate line rather than a missing feature — see
[Scope & safety](/guide/scope) — but it does mean bleach can point at ~900 MB
of Autodesk and Microsoft updater leftovers and then leave you to it.

## UUID-named containers are unknowable

`~/Library/Containers` holds UUID-named sandbox containers whose
`.com.apple.containermanagerd.metadata.plist` is entitlement-protected and
unreadable. An owner can never be established for these, so they are
permanently protected. On the development machine that's a meaningful fraction
of 932 container directories.

## Staleness is circumstantial

"Untouched for 200 days" doesn't prove abandonment. That's why staleness alone
never produces an actionable verdict — it has to combine with "no inventory
source claims this". Plugins can do better when they know the format: the
bundled `claude-code-sessions` plugin checks whether a session's *project*
still exists, which is categorical rather than circumstantial.

## The user-data heuristic can miss things

Detection works on file extensions and names, with cache-like names excluded.
A bespoke format in an unowned directory could slip past it.

This is the main argument for leaving the default
[quarantine mode](/guide/disposal-modes) alone rather than reaching for
`--mode delete`.

## No signing or notarisation

Release binaries are unsigned, so Gatekeeper will block the first run until you
clear the quarantine attribute:

```sh
xattr -d com.apple.quarantine /usr/local/bin/bleach
```

Building from source avoids this.

## Not tested below macOS 13

`Package.swift` targets macOS 13, but development and CI both run on a much
newer release. Older systems are untried rather than known-broken.
