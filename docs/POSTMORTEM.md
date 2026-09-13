# Incident: pathological disk I/O and watchdog freezes

**Date:** 2026-09-05 · **Host:** MacBook Air, Apple M-series, 24 GB RAM, 512 GB SSD
**Symptom:** machine freezes and watchdog timeouts; Activity Monitor reads spiking toward 1 GB/s
**Root cause:** pagein thrash on a saturated 24 GB machine with a 93%-full disk
**Resolution:** reclaimed 84.8 GB · **Hardware fault: none**

---

## Timeline

| Time | Event |
|---|---|
| 13:26 | `JetsamEvent` — kernel memory-pressure killer fires |
| 15:55 | macOS excessive-disk-write monitor trips twice |
| ~20:50 | Investigation opens with `smartctl` output |
| 21:00 | Disk found at 93% (34 GiB free); 4 local snapshots |
| 21:05 | Snapshot thin → +9 GiB |
| ~21:15 | Homebrew cache cleared — free space does not move (snapshot re-pin) |
| 21:30 | Xcode + dev caches cleared, TM paused, thin → 100.3 GB free |
| ~21:40 | Docker Desktop self-exits, compacts `Docker.raw` 42 G → 22 G |
| 21:50 | 121.4 GB free · load 10.76 → 2.29 · Spotlight/Drive loop closed |

---

## What the evidence said

SMART was clean on every field that matters — `Critical Warning 0x00`,
`Available Spare 100%`, `Percentage Used 0%`, `Media and Data Integrity Errors 0`.
The drive was never the problem.

The lifetime counters pointed at the real cause:

```
Data Units Read:     39.5 TB     ← 90 GB/hour over 438 power-on hours = 25 MB/s sustained
Data Units Written:  13.8 TB
```

A 2.9:1 read:write ratio at 90 GB/h is not a workload. It is pagein thrash.
Confirmed live:

```
Pageins:  1,043,671  (~16 GB in a 16-minute uptime)
Pageouts:     6,233
PhysMem:  23G used, 259M unused
vm.swapusage: total = 0.00M
```

Swap at zero beside saturated RAM is a signal, but not the one first assumed.
There were 36.6 GB free — far more than a swapfile needs — and swapouts stayed at
0 for the whole boot, meaning macOS never attempted one; the compressor was
coping. The disk being 93% full is measured, the thrash is measured, and the
causal arrow between them is inference. See lesson 12. Page cache
evicted executables, which were immediately re-read from SSD, at gigabytes per
second, until the kernel stalled long enough to trip the watchdog.

Aggravating factors, all visible in `DiagnosticReports`: Time Machine backing up
to a network NAS throughout, Spotlight indexing a Google Drive mount that was
simultaneously materializing files on access, a stopped 42 GB Docker VM image,
two `gopls` instances at 767 MB combined, and three container runtimes installed
side by side.

---

## Where the 84.8 GB came from

| Source | Reclaimed |
|---|---|
| Docker Desktop compacting `Docker.raw` on clean exit | 20 GB |
| Xcode `iOS DeviceSupport` | 22 GB |
| Local Time Machine snapshots | 9 GB |
| Homebrew cache (incl. 8 vendored Rubies) | 9 GB |
| Xcode `DerivedData` + JetBrains/go-build/rattler caches | ~11 GB |
| Everything else | ~14 GB |

---

## Lessons that became code

1. **Snapshots silently absorb deletions.** Clearing 8.9 GB of Homebrew cache
   moved free space by *zero* because a snapshot minted minutes earlier still
   referenced it. → `reclaim.zsh` pauses TM and thins at the end.

2. **Pausing Time Machine must be self-restoring.** It was left off for ~30
   minutes because a manual `tmutil disable` had no counterpart. → `sc_tm_pause`
   installs a `trap … EXIT INT TERM`.

3. **`err_return` is wrong for diagnostics.** The first `disk-report.zsh` aborted
   silently at the SMART section: `smartctl` exits 4 on the benign Apple
   GetLogPage artifact. The script was killed by the exact error the script
   exists to explain away.

4. **Transient 500s ≠ wedged daemon.** Docker's API was probed mid-shutdown and
   read as hung. It was Resource Saver stopping the VM; left alone, it exited
   cleanly and compacted 20 GB. A `kill -9` would have lost that and risked the
   Postgres volumes.

5. **A clean Docker shutdown is a reclaim strategy.** It out-performed the entire
   planned prune (20 GB vs ~25 GB estimated) and required no decisions.

6. **Exclude the cloud-sync parent, not the visible child.** Excluding `My Drive`
   left `Other computers/` and `.shortcut-targets-by-id/` indexed.

7. **Time Machine had been dead for 62 days and said nothing.** `SnapshotDates`
   (actual completed backups) runs 05-24, 06-09, 07-04, 07-05, 07-06 — then stops
   until 09-06. `AttemptDates` shows a longer gap, but it does not record every
   attempt; reading it as a completion gap overstates the outage. `ReferenceLocalSnapshotDate` pointed at
   `com.apple.TimeMachine.2026-07-06-094434.local` — the snapshot found marked
   **`(dataless)`**: macOS had purged its contents under space pressure, leaving
   TM with no baseline to diff against. Every backup since failed, retrying nine
   times on the final day, burning CPU and I/O into the same storm. Settings
   showed Time Machine "on" throughout.

   Thinning that snapshot during cleanup forced TM to abandon the broken chain
   and start a 350 GB full re-seed — the correct outcome, but note the chain was
   already unusable before we touched it.

   → `sc_tm_days_since_backup` now checks the age of the last *completed* backup
   in both the report and the guard, reading the world-readable TM plist so it
   works unprivileged under launchd.

8. **The re-seed exposed a second backup problem.** The 350 GB full backup ran
   ~10 hours and was still at 62% the next morning. Not sleep, not a restart, not
   power — throughput had collapsed from 21.9 MB/s to 1.4 MB/s while `backupd`
   burned 173% CPU at 7.5 files/sec, grinding sparsebundle band files over SMB.
   Wi-Fi was pristine throughout (-47 dBm, 1080 Mbps, 802.11ax).

   Cause: 75 GB across eleven reconstructible directories — Docker images, Apple
   container images, `.cache`, `.ollama`, toolchains — were being backed up, and
   the file count that came with them is what a network destination actually
   pays for. `Docker.raw` alone is a 22 GB sparse image rewritten on every
   container run.

   → `SC_TM_EXCLUDE_CANDIDATES` + `sc_tm_excluded` now flag this in the report,
   emitting a ready-to-paste `tmutil addexclusion -p` command. Report-only by
   design; it is a one-time fix, not something to notify about hourly.

9. **A monitor must distinguish current state from history.** The first guard
   treated jetsam reports as an escalating signal, so after the disk was fixed it
   kept reporting WARN for three days over kills that had already stopped. It
   also hardcoded `"Disk ${level}"` into every notification title and built the
   body from the disk branch alone — so the stale-backup CRIT rendered as
   **"Disk CRIT: 22% free"** on a machine with 121 GB free, naming the wrong
   subsystem and contradicting its own thresholds.

   → Two tiers. CHECKS are current conditions and escalate; NOTES are historical
   context and never do. Each check owns its verdict and its wording, the overall
   level is the worst check, and the notification names that subsystem.

10. **An orphaned backup that nothing can delete.** Every backup logged 48
    failures per 12 hours trying to reap `2026-05-24-080252.previous`. Three tools
    refused it for three unrelated reasons:

    - `tmutil delete` → error 22, *Invalid deletion target*. The `.previous` name
      keeps it out of the backup index, and tmutil only acts on indexed backups.
    - Time Machine's own thinning → `Expected SnapshotInProgressContainer metadata
      type but found APFSBackup`. A *completed* backup wearing an *in-progress*
      name, so thinning will not touch it.
    - `rm -rf` → `Directory not empty` on a directory that both `ls` and
      `find -mindepth 1` report as empty, with its Time Machine xattr already
      stripped. Entries are filtered out of `readdir` while `rmdir` still counts
      them; you cannot unlink what you cannot name.
    - Deleting it on the NAS → **impossible**. The destination is a single
      sparsebundle (`diskutil` reports `Protocol: Disk Image`, case-sensitive
      APFS, backed by `TimeMachineBackup/<host>.sparsebundle`). On the NAS there
      is no such directory — only opaque band files. The structure exists solely
      inside the disk image.

    Three theories were wrong on the way. A Spotlight lock: 73 `mds_store`
    handles were open on the volume, but none provably on this path. The
    `com.apple.timemachine.private.directorycompletiondate` xattr: removed
    successfully, `rmdir` still refused. And an SMB server hiding entries: wrong
    layer entirely — directory operations run in macOS's APFS driver against a
    locally-mounted image, and SMB only carries band files.

    **Check what a volume physically is before proposing a fix for it.**
    `diskutil info` would have ruled out the NAS-side route immediately.

    Left in place — it costs one failed `rmdir` per backup and no space, and
    cannot affect restores because it is not in the index.

    The generalisation worth keeping is about *stopping*. This began as "why does
    my Mac freeze" and ended at "an empty folder annoys Time Machine's logger".
    Knowing which findings deserve a fourth attempt and which deserve a footnote
    is part of the work.

11. **Spotlight indexing the backup destination is intended, not a leak.** 92
    `mds_store` handles on an 819 GB sparsebundle looked like obvious waste. It
    is not: nearly all of them are on `.Spotlight-V100/Store-V2` *on the
    destination*, and that index is what powers the search field in Time
    Machine's own browser.

    Two attempts to "fix" it failed informatively. `mdutil -i off <volume>` does
    nothing useful — it drops to `kMDConfigSearchLevelFSSearchOnly` and still
    reports `Indexing enabled`. And Search Privacy refuses the volume outright:
    *"is a Time Machine backup folder. You cannot add it to the privacy list."*

    When the operating system actively prevents a fix, that is evidence before it
    is an obstacle. A plausible mechanism and a real measurement still produced
    the wrong conclusion; only attempting the fix caught it.

    (The Google Drive exclusion in lesson 6 is a different case and remains
    correct — user volumes can be excluded, Time Machine destinations cannot.)


12. **The tidiest mechanism was the one I could not prove.** For most of a day
    the working theory was "the disk is too full for macOS to create a swapfile,
    so memory pressure has nowhere to go." It explains every symptom and it is
    probably wrong: there were 36.6 GB free, far more than the gigabyte a
    swapfile needs, and `swapouts` stayed at 0 for the entire boot — macOS never
    attempted one, because the compressor was holding 9.4 GB of pages in 3.9 GB
    and coping. That day's `JetsamEvent` reason was never read before macOS
    rotated the file away, so it cannot be claimed as confirmation either.

    What is measured: the disk was 93% full, RAM was saturated, and the drive was
    serving 18 MB/s of re-reads. What is inference: the arrow from the first to
    the second.

    The related trap is arithmetic. "90 GB per hour" sounds catastrophic and is
    25 MB/s — a grind, not a spike. Any reviewer does that division in their head,
    and a piece that has not done it first has already lost them. Do the division
    yourself, in public.

13. **Threshold alerting beats forensics.** Every signal — jetsam events, disk-write
   diags, falling free space — was present for days beforehand. Nothing was
   watching. → `disk-guard.zsh` + launchd.

14. **The backup-age check had the same blind spot it was built to catch.**
    Lesson 7 replaced "is Time Machine on" with "how old is the last *completed*
    backup". On a later incident on the same machine, that check reported
    `Backup 1d ago — OK` through **19 consecutive failures over 33 hours**.

    The mechanism is identical, one level up. `SnapshotDates` records
    completions, so a chain attempting hourly and failing every time does not
    age — it freezes at the last success. For a full day the number is
    indistinguishable from healthy, and by the time it crosses `SC_TM_WARN_D`
    the destination is already two days behind.

    Age is a *lagging proxy* for "backups are working". The direct signal was in
    the same plist the whole time: `RESULT`, the outcome of the most recent
    attempt — `26`, `BACKUP_FAILED_DISCONNECTED_NETWORK`, throughout. The cause
    was unremarkable once visible: a laptop backing up to a NAS over Wi-Fi,
    entering clamshell sleep every few minutes and dropping the SMB session
    mid-copy. 58 of 60 SMB reconnects landed within five seconds of a sleep
    transition. Seventy minutes awake fixed it. Nothing was ever damaged — Time
    Machine aborts the attempt and retries, which is exactly why it stayed quiet.

    → `sc_tm_last_result` and a `Last attempt` check, separate from `Backup` so a
    healthy age cannot mask a failing outcome. WARN on the first failing
    observation, CRIT after `SC_TM_FAIL_CRIT_H` (12 hours). It reads `RESULT`
    through the same unprivileged `defaults read` the date comes from: the plist
    is not world-readable and `tmutil latestbackup` needs Full Disk Access that a
    LaunchAgent will never have.

    The generalisation: **a check built from the artifact of success can only
    ever report success.** Lesson 9 said a monitor must separate current state
    from history. This is that error wearing different clothes — measuring the
    thing that moves only when the system works, and reading its stillness as
    health.

15. **Helpers that exist but are never consulted.** `sc_tm_running` had been in
    `common.zsh` since the health model landed, used in exactly one place: a
    status line in the report. Neither `sparkling-clean thin` nor `reclaim
    --apply` ever asked, and both are destructive to a backup in flight — `thin`
    runs `tmutil` at urgency 4 against snapshots the running backup is reading
    from, and `reclaim` pauses TM with `tmutil disable`, which stops it outright.

    Neither endangers what is already on the destination. What they cost is the
    run in progress — the expensive outcome precisely when a chain has been
    failing and one attempt has finally started to land.

    → Both refuse while a backup is running; `SC_ALLOW_DURING_BACKUP=1`
    overrides. Found while fixing it: the progress percentage both would print
    was parsed with `[0-9.]+`, which truncates `2.466504299824327e-06` — a real
    value ten seconds into a backup — at the exponent, rendering 0.0002% as
    **246.7%**. One shared `sc_tm_progress_pct` now, instead of two copies of the
    broken expression.
