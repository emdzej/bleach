# The TUI

```sh
bleach tui
```

Browse the scan, read the evidence behind each verdict, select what you want
gone, then either write a plan or apply directly.

```
 bleach  4146 paths · 128G measured   47 selected · 12.8G
 CACHE-SAFE 12.8G · ORPHAN? 2.3G · REVIEW 65.4G · PROTECTED 50.3G · UNKNOWN 759M

 TIER       SIZE   AGE    WHERE          NAME
●CACHE-SAFE  1.4G  57d    xdg-cache      opencode
●CACHE-SAFE  1.1G  today  plugin:openco… opencode bin          ·opencode-sessions
 ORPHAN?     854M  20mo   app-support    com.isaacmarovitz.Whisky
·PROTECTED  15.2G  today  containers     com.docker.docker
·ORPHAN?     529M  3mo    sys-app-supp…  Autodesk/AcActivityInsights ⚿
────────────────────────────────────────────────────────────────────────────
 /Users/you/Library/Application Support/com.isaacmarovitz.Whisky
 owner: unresolved   files: 1204
   clean  noOwnerFound: no installed app claims "com.isaacmarovitz.Whisky"
   clean  stale: nothing modified inside for 617 days
 1/4146                space select · a all · t tier · / search · w plan · x apply
```

## Keys

| Key | Action |
| --- | --- |
| `j` `k` `↑` `↓` | move |
| `ctrl-f` `ctrl-b` `PgUp` `PgDn` | page |
| `g` `G` | first / last |
| `space` | select row |
| `a` | select everything selectable in this view |
| `c` | clear selection |
| `t` | cycle tier filter |
| `/` | search name, path, or owner |
| `w` | write a plan file and exit |
| `x` or `A` | apply now — opens the confirmation modal |
| `?` | help |
| `q` `Esc` | quit |

## Reading the list

The leading glyph tells you whether a row is selectable:

| Glyph | Meaning |
| --- | --- |
| `●` | selected |
| `·` (dim) | cannot be selected |
| space | selectable, not selected |

Trailing markers explain *why* a row isn't selectable:

| Marker | Meaning |
| --- | --- |
| `⚿` | outside `$HOME`; needs `sudo`, so bleach won't act on it |
| `⊂` | contains finer-grained rows — select those instead |

Rows sourced from a plugin show the plugin name after the path, like
`·opencode-sessions`.

Pressing `space` on an unselectable row prints the reason in the status bar
instead of silently doing nothing.

## The detail pane

Always shows the full path, the resolved owner with the inventory sources that
found it, and up to four evidence signals. Each is tagged:

- `keep` — argues the path is in use
- `clean` — argues it's abandoned
- `info` — context, no weight

An owner that was identified but isn't actually installed is flagged
explicitly: `Slack — identified but not installed [installReceipt]`. That's the
stale-pkg-receipt case, and seeing it stated is the difference between trusting
the verdict and guessing.

## Applying

Press `x`. A modal states what will happen before it accepts anything:

```
   Apply to 47 paths · 12.8G

   ▸ quarantine     moved to ~/.local/state/bleach/quarantine — undo with `bleach restore`
     Trash          moved to Finder's Trash — undo from Finder, still using disk until emptied
     delete in place  unlinked immediately — NO undo

       1.4G   /Users/you/.cache/opencode
       1.1G   /Users/you/.local/share/opencode/bin
       1.0G   /Users/you/Library/Caches/lens-desktop-updater
     … 44 more

   Reversible: moved to ~/.local/state/bleach/quarantine — undo with `bleach restore`

 mode=quarantine                    m cycle mode · enter confirm · esc cancel
```

`m` cycles the [disposal mode](/guide/disposal-modes). `Enter` confirms, `Esc`
cancels.

Choosing **delete in place** changes the modal: it turns red, states the byte
count with no undo, and requires you to type the word `delete` in full. A
single keystroke is too cheap for an irreversible action. Switching modes
clears anything you've typed, because the word was consent for the *previous*
mode.

### What happens after you confirm

The TUI leaves the alternate screen and then **re-runs full validation against
live state** before touching anything. The scan behind the screen may be many
minutes old; processes start, directories grow. Confirmation is consent, not
verification — those are separate steps on purpose.

Refusals are printed individually:

```
  mode: quarantine
  skip  1.2G   …/Library/Caches/JetBrains/IntelliJIdea2026.2 — a process is running from this path
  quarantined 46 paths · 11.6G

  batch 20260917-114203
  undo:    bleach restore 20260917-114203
  commit:  bleach quarantine --purge --all
```

`bleach tui` and `bleach apply` share one execution path, so validation,
journalling and skip reporting cannot drift between them.

## Selecting REVIEW rows

By default the TUI lets you select `REVIEW` rows, but `apply` refuses them.
Pass `--allow-review` to permit them:

```sh
bleach tui --allow-review
```

Worth doing deliberately rather than habitually — `REVIEW` is where bleach is
telling you it isn't sure.

## Notes

- The terminal is restored on every exit path, including `SIGINT`, `SIGTERM`
  and `SIGHUP`, so a crash can't leave you in an alternate screen with an
  invisible cursor.
- Resizing is handled: the layout re-queries terminal size on every frame.
- The TUI needs a real terminal. Piped input exits with
  `bleach tui needs a terminal`.
