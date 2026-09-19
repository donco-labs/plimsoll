# plimsoll

A zero-dependency macOS disk triage toolkit. Diagnose disk-pressure freezes,
reclaim space safely, and get warned before it happens again.

Named for the *Plimsoll line*, the mark on a hull showing how heavily a ship may
safely be loaded. Cross it and you founder — which is roughly what a Mac does at
93% full. Everything here is either a way of reading where that line sits or a
way of getting back above it.

macOS abstracts away filesystem realities to keep the experience seamless. That
works until you combine a nearly-full disk, a slow backup destination and a heavy
developer toolchain — at which point the abstractions stop protecting you and
start hiding the problem.

Born from a real incident: a 24 GB MacBook Air freezing under watchdog timeouts,
with the drive serving a sustained **18 MB/s of pagein thrash** — memory pressure
wearing a disk costume. The SSD was healthy: 0 media errors, 0% endurance used.
The disk was 93% full, Time Machine had not completed a backup in 62 days, and
nothing had said so. Full writeup, including which theories turned out wrong:
[docs/POSTMORTEM.md](docs/POSTMORTEM.md).

## Install

```bash
brew tap donco-labs/tap
brew trust --formula donco-labs/tap/plimsoll
brew install plimsoll
```

Homebrew 6.0 refuses to load formulae from third-party taps until you trust them
— a formula is arbitrary Ruby that runs on install, so this gate is doing its
job. `--formula` trusts only this one; `brew trust donco-labs/tap` would trust
every formula the tap ever gains. Trust is recorded in
`~/.homebrew/trust.json` (or `$XDG_CONFIG_HOME/homebrew/trust.json`).

The formula is [Formula/plimsoll.rb](https://github.com/donco-labs/homebrew-tap/blob/main/Formula/plimsoll.rb)
— worth a read before you trust it, as with any tap.

Or clone and use `make` directly — the repo works without installing.

## Quick start

```bash
plimsoll report   # or: make report          # what is going on — read-only, changes nothing
```
```bash
make dry             # what a cleanup would free — removes nothing
```
```bash
make clean-safe      # reclaim caches that regenerate silently
```
```bash
make install-guard   # launchd watchdog: checks every 2h, notifies on WARN/CRIT
```

### Menu bar

```bash
brew install --cask swiftbar
mkdir -p "$HOME/Library/Application Support/SwiftBarPlugins"
ln -sf "$(brew --prefix)/opt/plimsoll/libexec/extra/swiftbar/plimsoll.10m.sh" \
       "$HOME/Library/Application Support/SwiftBarPlugins/"
open -a SwiftBar
```

Point SwiftBar at that folder on first launch. **Use a dedicated folder, not
`~/Library/Application Support/SwiftBar`** — that is SwiftBar's own state
directory, and it writes `Diagnostics/latest-system-report.txt` there, chmods it
executable, and then loads its own report as a plugin. You get a second menu bar
item showing `?` and "Show Error", and nothing about it suggests where it came
from.

Quote the destination rather than backslash-escaping the space — the escape does
not survive being copied out of a terminal or a rendered page. Create the folder
first as well, as the `mkdir` above does: SwiftBar has no plugin directory until
its first launch, so `ln` fails on a missing target.

**Submenus grey out on SwiftBar 2.1.0–2.1.1.** The Watchlist and About headers
turn grey and stop opening after the plugin refreshes with any changed row —
which, for a health monitor, is constantly. It is a SwiftBar bug, not a plugin
one: 2.1.0 reworked incremental menu updates to reuse menu items, and 2.1.2
BETA 1 lists *"Fixed submenu parents becoming disabled after incremental child
or title changes"*. Quitting and relaunching SwiftBar restores them until the
next change; Refresh does not, because it reuses the same status item. See
[swiftbar/SwiftBar#521](https://github.com/swiftbar/SwiftBar/issues/521).

The real fix is the beta, which is notarized and signed by the same team as the
stable build (`X93LWC49WV`):

```bash
curl -fsSLO https://github.com/swiftbar/SwiftBar/releases/download/v2.1.2-beta-3/SwiftBar.v2.1.2.b607.zip
unzip -q SwiftBar.v2.1.2.b607.zip
osascript -e 'quit app "SwiftBar"' ; sleep 3
rm -rf /Applications/SwiftBar.app && ditto SwiftBar.app /Applications/SwiftBar.app
open -a SwiftBar
```

Beta 3 is cumulative and carries two more fixes worth having. One restores
plugin-name lookup for the `swiftbar://refreshplugin` URL
([#527](https://github.com/swiftbar/SwiftBar/issues/527)) — that is what
`plimsoll thin` calls, so the menu bar stops showing a stale snapshot
warning the moment you thin rather than up to ten minutes later. The other
preserves explicit SF Symbol rendering, which is how the menu bar icon is drawn.

**Row colour is an ANSI escape, not the `color=` parameter.** On macOS 26,
SwiftBar wraps any row styled with `color=` in a tracking subclass that forces
the selected-item text colour while the pointer is over it, and the restore on
the way out does not take: the row keeps the highlight colour until the whole
menu is rebuilt. An orange WARN went dark on rollover and stayed dark until the
menu was closed and reopened. ANSI-coloured rows are exempt from that wrapper,
so every coloured row carries a `\e[38;5;NNNm` prefix and `ansi=true`. The
`color=` parameter stays on the row regardless — SwiftBar gives a row a target
only when it has an action *or* a colour, and a targetless row is auto-disabled:
dimmed, and refusing to highlight at all. Verified against 2.1.2 beta 3.

**Homebrew still records the stable version afterwards.** The cask is
`auto_updates`, so brew will not revert it on its own — but a cask upgrade will,
silently, and the grey submenus come back with it. That is also the rollback if
you want one:

```bash
brew reinstall --cask swiftbar     # back to the stable build
```

On first launch SwiftBar asks which folder to use — point it at that one. It is
notarized but ships quarantined, so macOS shows its standard first-run dialog;
approve it in System Settings → Privacy & Security → Open Anyway.

The dropdown also carries a **Watchlist** — the directories where space actually
accumulates, with `~/Downloads` and the toolchain caches included. Sizing them
costs about ten seconds of directory walking, so it is cached and refreshed
roughly twice a day by the background guard rather than measured on every
render: a disk monitor that generated sustained I/O would be causing the problem
it exists to detect. The numbers are up to half a day old, which is the right
resolution for watching creep.

Each refresh is also **appended to a history** rather than overwriting the last
one, which turns a size into a trend: every row shows which way it has moved
over the past week, and the footer totals that movement across the whole set.
The window says how far back to look; the wording says how much history was
actually there, so a delta drawn from two samples reads `over 12h` rather than
claiming a week it cannot see.
Movement under 50 MB reads as `steady`, because `du` rounds and caches breathe.
A row with only one measurement behind it says `new` and nothing more — that is
every row for the first week after the history starts. Samples are pruned at 180
days and cost a couple of KB a day.

Rows are **grouped by what would reclaim them**, so the list says not just where
the space is but what to do about it: `plimsoll reclaim`, the same with
`--tier 2`, `plimsoll docker`, and a `Yours` group for data nothing
automated will ever delete. Headings name the CLI rather than the make targets,
because a Homebrew install has no Makefile — and because the CLI form is
dry-run until you add `--apply`, where `make clean-safe` already carries it. The
heading tooltips give the make shortcut for anyone working from a clone. `(part)` marks a directory where only a subtree is reclaimed —
`~/Library/Caches` is watched whole, but tier 1 removes eight named children of
it. That mapping is a table in `common.zsh` rather than something derived from
`reclaim.zsh`, whose rules are globs and tool invocations; `make lint` fails if
the table and the watch list drift apart. Hovering any row gives the full
story: current size, the week's delta, a sparkline, and what the matching target
would actually take.

Shows a monochrome SF Symbol and nothing else when healthy — a template image, so
it follows the menu bar appearance like any native item. Severity is weight rather
than a different symbol: `internaldrive` when healthy, filled on a warning, and
only a genuine emergency changes the glyph to a caution triangle. It never shows
text, at any severity — menu bar width is shared with every other app, and the
worst check's subject on its own is a bare noun that names a category rather
than a state. The triangle says "open me"; the dropdown says what and why. The
drive stays recognisable in a crowded menu bar either way. The
dropdown gives one row per check and puts the explanation in a **tooltip** —
hover any row, healthy or not, to read what it is measuring and against what.
That keeps the menu to one line per check instead of spending up to five rows
on a sentence, and it costs nothing to explain the OK rows too. Nothing is
hidden by it: a condition worth acting on is *pushed* as a notification built
from the same text, so the dropdown is the passive surface rather than the only
one. Actions still get rows of their own, because a fix nobody can find is not
a fix: when
snapshots are holding space, it hands you `plimsoll thin` rather than
describing the problem and leaving you to search for the remedy. Reads the guard's `--json` (0.4 s) rather than the full report (tens of
seconds), so it is cheap to refresh.

Deliberately not a bundled app: `tmutil addexclusion` needs Full Disk Access,
snapshot thinning needs root, and a DMG needs Developer ID notarization to avoid
Gatekeeper. SwiftBar is already notarized and brew-installable, so this is ten
lines of config instead of a signing pipeline.

## Make targets

`make help` lists these at any time.

| Target | Does |
|---|---|
| `make report` | Full read-only diagnostic, ending in a Verdict block |
| `make brief` | Headline numbers only |
| `make check` | Run the guard once — exit `0` ok / `1` warn / `2` crit |
| `make dry` | Preview a tier 1+2 reclaim. Removes nothing |
| `make clean-safe` | Reclaim tier 1 — caches that regenerate silently |
| `make clean-more` | Reclaim tier 1+2 — adds re-downloadable caches |
| `make review` | List tier-3 *data* candidates for manual decision |
| `plimsoll thin` | Release space held by local Time Machine snapshots |
| `make docker` | Report Docker reclaimable space. Never touches volumes |
| `make docker-clean` | Prune build cache + untagged images, then compact |
| `make tm-status` | Which codified Time Machine exclusions are applied |
| `make tm-exclude` | Preview applying the exclusion list |
| `make tm-exclude-apply` | Apply it (needs Full Disk Access) |
| `make install-guard` | Install + load the launchd watchdog |
| `make uninstall-guard` | Unload + remove it |
| `make guard-status` | Is the guard loaded? |
| `make log` | Tail the guard's health log |
| `make plugin-dev` | Point the menu bar at this checkout, for live edits |
| `make plugin-brew` | Point it back at the Homebrew copy |
| `make plugin-status` | Which copy is the menu bar running? |
| `make plugin-refresh` | Redraw the menu bar now |
| `make lint` | Syntax-check every script and the plist |

## The guard

A launchd LaunchAgent labelled `com.plimsoll.diskguard`. Checks every
2 hours plus once at login.

| What | Where |
|---|---|
| Installed plist (what launchd reads) | `~/Library/LaunchAgents/com.plimsoll.diskguard.plist` |
| Script it runs | `bin/disk-guard.zsh` |
| Shared check logic | `bin/lib/common.zsh` → `pl_run_health_checks` |
| Plist template (in git) | `launchd/com.plimsoll.diskguard.plist` |
| Health log | `~/.local/state/plimsoll/plimsoll.log` |
| Notification state | `~/.local/state/plimsoll/guard.state` |
| Backup-failure clock | `~/.local/state/plimsoll/tm.state` |
| Last-backup size cache | `~/.local/state/plimsoll/tm-last.tsv` |
| launchd stdout / stderr | `.guard.out.log` / `.guard.err.log` (gitignored) |

The template carries a `__PL_ROOT__` placeholder that `make install-guard`
substitutes with this repo's absolute path, so the installed plist is generated
rather than hand-edited.

**Editing the scripts takes effect immediately.** The plist runs
`bin/disk-guard.zsh` in place, not a copy, so the next scheduled run picks up
your changes. Re-run `make install-guard` only if you *move the repo* or change
the plist itself.

Force a run instead of waiting:

```bash
launchctl kickstart -k gui/$(id -u)/com.plimsoll.diskguard
```

launchd rather than cron: it runs a missed interval on wake, so a sleeping laptop
still gets checked, and it runs inside the GUI session that notifications need.

### When it speaks

It **checks** every 2 hours; it **notifies** only on a level change, or once per
12 hours (`PL_RENOTIFY_H`) while a condition persists. Never on OK.

**A silent notification tray is the healthy steady state** — use `make log` to
confirm it is alive.

One condition is deliberately silent even at WARN: `Last attempt: destination not reachable`
when it is the *only* thing wrong. A laptop that leaves the house every weekday
cannot reach a NAS at home, and a notification every morning about the expected
consequence of commuting trains you to dismiss the guard unread. The row still
reads WARN in the report and the menu bar and the exit code is still `1` —
backups genuinely are not happening — but nothing is pushed. Add a second
complaint and it speaks again: away *and* a filling disk is news. So is any
CRIT, which is what the Backup age row escalates to if you stay away past
`PL_TM_CRIT_D`. `--force` ignores the suppression.

Signals come in two tiers:

| Tier | Contents | Escalates | Notifies |
|---|---|---|---|
| **CHECK** | disk %, Time Machine on/off, backup age, last attempt outcome, snapshot count | yes | yes |
| **NOTE** | jetsam / panic history | no | no |

Jetsam reports are evidence something *already happened*. Treating them as an
escalating signal keeps the guard at WARN for days after you fix the cause —
exactly when a monitor most needs to go quiet. If the cause is still live, disk %
or backup age catches it as a *current* condition.

Each check owns its own verdict and wording; the overall level is the worst
check, and the notification names **that** subsystem — `Backup CRIT: 61 days
stale`, not `Disk CRIT` on a machine with 121 GB free.

```
== Verdict ==
  OK    Disk          22% free (109.2 GB)
  OK    Backups       enabled · hourly
  OK    Backup        Wed 21:10 · 1.5 GB of 172.6 GB in 11m
  OK    Last attempt  ok
  OK    Snapshots     2
  note  2 jetsam/panic report(s) in the last 3 days (past events, not a current fault)

OK    healthy
```

### What the backup rows do and do not claim

`Backups: enabled · hourly` is the **configured cadence** (`AutoBackupInterval`),
not a promise about when the next one runs. macOS hands the actual firing to its
activity scheduler, which defers on power, thermal state, network and what you
are doing. Measured gaps on one laptop against a 3600-second setting:

```
29  38  40  42  55  56  98  109  113  156  646   minutes
```

So there is deliberately no "next backup at 21:51" anywhere in this toolkit.
Nothing exposes a next-fire time — not `tmutil`, not launchd, not `pmset` — and
a predicted one would be wrong more often than right. Stating a time confidently
and wrongly is the failure this whole project was written about.

`Backup: Wed 21:10 · 1.5 GB of 172.6 GB in 11m` names the moment the last
backup finished, what it wrote, and what it wrote into — read from backupd's
own summary. That ratio is also the full-versus-incremental answer, without
having to interpret any undocumented status string: a first backup writes
essentially the whole thing, so the two numbers converge.

All of it sits in the headline because the headline is the row: explanations
live in tooltips now, so anything not in the headline waits to be hovered. The
row carries a clock time rather than an
age because it only ever describes a backup younger than `PL_TM_WARN_D`; two
days is the widest gap it has to express, so a weekday disambiguates and no
date is needed, and today's backups drop the weekday entirely. `0d ago` said
the same thing about a backup five minutes old and one twenty-three hours old.
The WARN and CRIT rows still count in days, which is what those rows are for.

It comes from `log show --info`, which costs about a second and whose store
**retains roughly 15 hours** — a 3-day query returns byte-identical output to a
12-hour one. So the guard reads it once per completed backup and caches it
against that backup, and the clause is simply absent when the log no longer has
it. That means it disappears exactly when the chain has been failing for days,
which is fine: by then the Backup age row is the one talking.

Thresholds, overridable by env: `PL_WARN_PCT` (15), `PL_CRIT_PCT` (10),
`PL_TM_WARN_D` (2), `PL_TM_CRIT_D` (7), `PL_TM_FAIL_CRIT_H` (12),
`PL_RENOTIFY_H` (12).

**Backup age and backup outcome are separate checks, and they have to be.** Age
is read from `SnapshotDates`, which only ever records completions — so a Mac
attempting hourly and failing every single time still reports a healthy-looking
recent timestamp, and goes on reporting it until the age finally drifts past
`PL_TM_WARN_D` two days later. `Last attempt` reads `RESULT` instead, the outcome of the most recent
attempt, and names the cause rather than a second clock: `Last attempt CRIT: failed — network dropped
mid-copy`. How long it has been failing is in the row's tooltip, because the `Backup` row already owns
a duration and two near-but-unequal ones side by side are worse than either. It warns on the first failing check and escalates
after `PL_TM_FAIL_CRIT_H` hours, so a chain that stops working is caught on the
next two-hourly check rather than on day three.

## What is here

| Path | Purpose |
|---|---|
| `bin/disk-report.zsh` | Read-only diagnostic: space, snapshots, memory, jetsam events, SMART, offenders, TM exclusions, Verdict |
| `bin/reclaim.zsh` | Tiered reclamation, **dry-run by default** |
| `bin/docker-reclaim.zsh` | Docker space, **never touches volumes** |
| `bin/disk-guard.zsh` | Threshold watchdog; exit 0/1/2, desktop notification |
| `bin/lib/common.zsh` | Shared helpers — the APFS/snapshot/sparse-file knowledge and the health model live here |
| `launchd/` | LaunchAgent template for the guard |
| `docs/GUIDE.md` | **The comprehensive guide.** Why the tools mislead, how to read the evidence, what to clean in what order |
| `docs/REFERENCE.md` | Copy-paste command cheat sheet |
| `docs/POSTMORTEM.md` | The incident, and which lesson became which line of code |

## The four things worth knowing up front

Before running a single command: the standard macOS utilities are not telling you
the truth about your disk.

**1. `df` is misleading on APFS.** Volumes share one container, so `Size` and
`Avail` are container-wide and identical on every row — never sum them. `df -h`
also reports GiB while `diskutil` and Finder report GB. Use:

```bash
diskutil info /System/Volumes/Data | grep "Container Free"
```

**2. Local snapshots absorb your deletions.** Delete 9 GB, watch free space not
move. A Time Machine snapshot taken before the delete still references those
blocks. Always finish with a thin — `reclaim.zsh` does it automatically:

```bash
sudo tmutil thinlocalsnapshots / 999999999999 4
```

**3. Time Machine being "on" does not mean it is working.** A full disk purges
the local snapshot TM uses as its incremental reference; every backup then fails,
silently, for months. Check the age of the last *completed* backup:

```bash
defaults read /Library/Preferences/com.apple.TimeMachine | sed -n '/SnapshotDates/,/);/p' | tail -3
```

That date is necessary but not sufficient: it moves only on success, so it looks
healthy for a full day after the chain breaks. Ask what the *last attempt* did —
`0` is success, anything else is the failure code:

```bash
defaults read /Library/Preferences/com.apple.TimeMachine | grep RESULT
log show --last 24h --predicate 'subsystem == "com.apple.TimeMachine"' \
  | grep BACKUP_FAILED
```

Both are unprivileged, which is why the guard uses the first one — the plist is
not world-readable and `tmutil latestbackup` needs Full Disk Access, which a
LaunchAgent does not have.

And a chain that *is* working can still be mostly garbage — `make report` flags
large reconstructible directories (container images, package caches, toolchains)
that are in every backup. The list is codified in `PL_TM_EXCLUDE_CANDIDATES`
(`bin/lib/common.zsh`) and applied with one command, so a rebuilt machine gets
the same policy:

```bash
make tm-status          # what is applied vs pending
make tm-exclude-apply   # apply the whole list
```

**4. Never `docker volume prune`.** A named volume reads as "dangling" the moment
its container is removed, but it still holds your data. Volumes are a small share
of Docker's footprint anyway; build cache and untagged images are where the space is.

## Safety

- Dry-run by default; destructive paths need `--apply`
- Tier 3 (real data: LLM models, Downloads) is **reported, never deleted**
- Pausing Time Machine is restored by a `trap`, so an interrupted run cannot
  leave the machine unbacked-up
- No `err_return` — diagnostic tools exit non-zero on benign conditions
  (`smartctl` returns 4 on Apple's harmless GetLogPage artifact)
- History never escalates current state, so a fixed problem stops alarming
- The report and the guard share one `pl_run_health_checks`, so they cannot
  disagree about whether the machine is healthy

## Requirements

macOS (APFS). Optional: `smartmontools` for SMART, `terminal-notifier` for nicer
notifications. Everything else is stock.
