# Writing a bleach plugin

A plugin is any executable that speaks JSON on stdio. No Swift, no rebuild, no
linking — a 40-line script is a complete plugin.

Plugins exist because the valuable knowledge in a tool like this is exactly the
part that can't be generalised: which directory belongs to what, and which
parts of it are dead. That knowledge should be contributable without touching
the machinery that decides what is safe to remove.

## What a plugin can and cannot do

A plugin **proposes**. It never acts.

- It cannot delete, move, or write anything.
- It never receives file contents — only paths, names, and sizes.
- It can only speak about paths inside the scope it declared in its manifest.
  Anything else it returns is discarded and reported as a warning.
- It cannot weaken a protection. If bleach's core rules hard-protect a path, a
  plugin asking for it to be removed is recorded and ignored.
- Its evidence weights are clamped to ±10, so it cannot swamp core scoring.

Every path a plugin returns is re-validated before bleach will even measure it:

1. absolute, and existing on disk
2. inside the user's home directory
3. inside one of the plugin's declared `owns` prefixes
4. unchanged by path standardisation (blocks `..` traversal)
5. not a symlink

And then, because plugin output only ever becomes a *plan*, `bleach apply`
re-validates all of it again against live state.

## Discovery

bleach looks for plugins in:

1. `~/.config/bleach/plugins/`
2. every directory in `$BLEACH_PLUGIN_PATH` (colon-separated)
3. `./plugins/` relative to the working directory

A plugin is either an executable file, or a directory containing an executable
named `plugin`. Check what was found with:

```sh
bleach rules --plugins
```

## Protocol

Version 1. Three modes, selected by `argv[1]`.

### `manifest`

Called with no stdin. Print a manifest and exit 0.

```json
{
  "protocol": 1,
  "name": "my-tool-sessions",
  "description": "Stale my-tool session state",
  "capabilities": ["enumerate", "resolve"],
  "owns": ["~/.my-tool", "~/Library/Application Support/com.example.mytool"]
}
```

`owns` is a hard boundary, not a hint. Declare the narrowest scope that works.

### `enumerate`

Emit candidates *inside* your scope — this is how you split a directory bleach
would otherwise treat as one opaque blob.

Request on stdin:

```json
{ "protocol": 1, "home": "/Users/you", "stale_days": 180,
  "scope": ["/Users/you/.my-tool"] }
```

Response on stdout:

```json
{ "protocol": 1,
  "candidates": [
    { "path": "/Users/you/.my-tool/sessions/abc",
      "label": "my-tool session: /Users/you/code/deleted-project",
      "kind": "state",
      "tier_hint": "orphan_likely",
      "evidence": [
        { "kind": "noOwnerFound",
          "detail": "the project this session belongs to no longer exists",
          "weight": -8 }
      ] } ] }
```

Do **not** report sizes. bleach measures every candidate itself.

### `resolve`

Contribute evidence for candidates bleach already found. You are only shown
candidates inside your own scope — never a listing of the whole Library.

Request:

```json
{ "protocol": 1, "home": "/Users/you", "stale_days": 180,
  "candidates": [
    { "path": "/Users/you/.my-tool", "name": ".my-tool",
      "root_id": "dotdirs", "size_bytes": 12345678 } ] }
```

Response:

```json
{ "protocol": 1,
  "resolutions": [
    { "path": "/Users/you/.my-tool",
      "owner_name": "My Tool",
      "owner_bundle_id": "com.example.mytool",
      "tier_hint": "review",
      "evidence": [
        { "kind": "cacheRule", "detail": "rebuilt on next run", "weight": -2 } ] } ] }
```

## Fields

**`kind`** (candidate): `cache` or `state`. `cache` means regenerable.

**`tier_hint`**: `cache_safe`, `orphan_likely`, `review`, `protected`, or
`unknown`. An unrecognised value becomes `unknown` — report-only — rather than
anything actionable.

**`evidence[].kind`**: any of the core evidence kinds; the useful ones are
`noOwnerFound`, `ownerMissingFromDisk`, `stale`, `recentActivity`, `cacheRule`,
`userDataMarker`, `versionSibling`, `nameMatch`, `runningProcess`. Unknown
kinds degrade to a generic bucket instead of failing.

**`evidence[].weight`**: sign convention — **positive argues the path is in use
(keep), negative argues it's abandoned (clean)**. Clamped to ±10.

**`evidence[].detail`**: shown verbatim to the user, prefixed with your plugin
name. This is the whole point. Write the sentence you'd want to read before
deleting a gigabyte.

## Guidance

**Find a signal mtime can't give you.** The `claude-code-sessions` plugin
decodes session directory names back into project paths and checks whether the
project still exists. "The project this belongs to was deleted" is categorical;
"untouched for 200 days" is circumstantial. Look for the categorical one.

**Never propose the live database.** `opencode-sessions` deliberately omits
`opencode.db` from its candidate list entirely. Leaving something out is
cheaper than protecting it.

**Prefer `review` when unsure.** It's reported to the user but non-actionable
without an explicit opt-in. A plugin that lands everything in `orphan_likely`
will get uninstalled the first time it's wrong.

**Split by role, not by size.** A 2.8 GB directory reported as one line is
useless. The same directory split into "redownloadable tooling", "per-session
snapshots", and "live database" is immediately actionable.

## Skeleton

```python
#!/usr/bin/env python3
import json, os, sys

MANIFEST = {
    "protocol": 1,
    "name": "my-tool-sessions",
    "description": "Stale my-tool state",
    "capabilities": ["enumerate"],
    "owns": ["~/.my-tool"],
}

def enumerate_candidates(request):
    root = os.path.expanduser("~/.my-tool")
    out = []
    if os.path.isdir(root):
        for entry in sorted(os.listdir(root)):
            path = os.path.join(root, entry)
            if not os.path.isdir(path) or os.path.islink(path):
                continue
            out.append({
                "path": path,
                "label": "my-tool %s" % entry,
                "kind": "state",
                "tier_hint": "review",
                "evidence": [{"kind": "cacheRule",
                              "detail": "regenerated on next run",
                              "weight": -2}],
            })
    return {"protocol": 1, "candidates": out}

mode = sys.argv[1] if len(sys.argv) > 1 else "manifest"
if mode == "manifest":
    json.dump(MANIFEST, sys.stdout)
elif mode == "enumerate":
    json.dump(enumerate_candidates(json.load(sys.stdin)), sys.stdout)
else:
    sys.exit(2)
```

Drop it in `~/.config/bleach/plugins/`, `chmod +x`, and confirm with
`bleach rules --plugins`.

## Debugging

Plugins are ordinary programs, so run them by hand:

```sh
./plugins/my-plugin manifest | jq
echo '{"protocol":1,"home":"'$HOME'","stale_days":180,"scope":["'$HOME'/.my-tool"]}' \
  | ./plugins/my-plugin enumerate | jq
```

Failures never abort a scan. A plugin that crashes, times out (20s), or emits
bad JSON is skipped and reported by `bleach rules --plugins`.
