# Full Disk Access

macOS protects much of `~/Library` behind TCC. Without Full Disk Access,
bleach's directory walks hit permission denials, and every size it reports is
an undercount.

It tells you when this is happening rather than silently reporting less:

```
  ! 649 paths were unreadable — sizes are undercounts.
    Grant Full Disk Access to your terminal in
    System Settings > Privacy & Security > Full Disk Access.
```

## Granting it

1. Open **System Settings → Privacy & Security → Full Disk Access**
2. Click **+**
3. Add your terminal — `Terminal.app`, `iTerm.app`, `Ghostty.app`, or whichever
   you use. If you run bleach from an IDE's integrated terminal, add the IDE.
4. **Quit and reopen the terminal.** The permission is read at process start,
   so an already-running shell won't pick it up.

Then re-run `bleach scan` and confirm the warning is gone.

## Why bleach asks for the terminal, not itself

bleach is a plain command-line binary, so the TCC grant attaches to whatever
launched it. Adding the binary to the Full Disk Access list does nothing
useful; the parent process is what's checked.

## What happens if you don't

Everything still works, and nothing becomes unsafe — but:

- Sizes are undercounts, so a genuinely large orphan can look trivial and be
  filtered out by `--min-size`.
- `bleach apply` **refuses** any path whose walk hit a denial, with
  *"partially unreadable; grant Full Disk Access and rescan"*. Acting on a
  directory you could not fully measure is exactly the situation where a
  surprise lives in the part you couldn't see.

So the tool degrades to read-only-and-honest rather than to
confidently-wrong.
