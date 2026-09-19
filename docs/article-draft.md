# My Mac Was Reading 90 GB an Hour. The SSD Was Fine.

*A night of chasing a "failing disk" that turned out to be three separate problems, one of which had silently killed my backups two months earlier.*

---

It started the way these things do: the machine would freeze, hard, for ten or twenty seconds at a stretch. Watchdog timeouts. Activity Monitor showing disk reads spiking toward 1 GB/s with nothing obvious to explain it.

(Hold that number loosely. Activity Monitor reports instantaneous bursts, and a burst proves nothing on its own. The figure that mattered turned out to be far smaller and far more damning.)

A 24 GB M-series MacBook Air, 512 GB SSD, macOS 26. My first thought was the same as yours would be: the drive is dying.

So I pulled SMART data.

```
SMART overall-health self-assessment test result: PASSED

Critical Warning:                   0x00
Available Spare:                    100%
Percentage Used:                    0%
Media and Data Integrity Errors:    0
Error Information Log Entries:      0

Read 1 entries from Error Information Log failed:
GetLogPage failed: system=0x38, sub=0x0, code=745
```

That last line looked like the smoking gun. It is not.

## The red herring

`system=0x38` is IOKit. `code=745` is `kIOReturnDeviceError`. Alarming, and completely meaningless here.

Apple's NVMe driver exposes the health page, `0x02`. `smartctl` also asks for page `0x01`, the Error Information Log, and the driver refuses. I have seen this on every Apple Silicon Mac I have checked, and the smartmontools project documents the limitation — but I have checked a handful, not a population.

The tell is two lines above it: **`Error Information Log Entries: 0`**. There is nothing to read. `smartctl` tries to read one entry anyway, gets refused, and reports a device error.

It also makes `smartctl` exit with status 4 — which later killed the first version of my own diagnostic script, silently, at exactly the section written to explain the error away.

> **Takeaway.** On Apple Silicon, `GetLogPage failed … code=745` is a tool artifact, not a disk fault. Judge the drive by `Critical Warning`, `Available Spare`, `Percentage Used`, and `Media and Data Integrity Errors`. All four were perfect.

## What SMART actually told me

The health fields were clean. The lifetime counters were not normal.

```
Data Units Read:     77,217,786 [39.5 TB]
Data Units Written:  27,033,148 [13.8 TB]
Power On Hours:      438
```

39.5 TB read across 438 powered-on hours is 90 GB per hour, every hour the machine has ever been awake.

That sounds apocalyptic until you divide it out: **25 MB/s**. Which is the point. This was never a spike — it is a grind, running continuously for the life of the drive, low enough that nothing ever flagged it and relentless enough to add up to 39.5 TB.

The read:write ratio is nearly 3:1. On its own that proves little; compiling, container pulls and model loading all read far more than they write. What it did was tell me where to look next, and looking next is what produced actual evidence:

```
Pageins:   1,043,671      (~17 GB — in a 16-minute uptime)
Pageouts:      6,233
PhysMem:   23G used, 259M unused
vm.swapusage: total = 0.00M
```

A million pageins against six thousand pageouts. The machine was not writing; it was reading the same pages back, over and over. Work that out and it comes to **18 MB/s of pure re-reading** — the same order as the drive's lifetime average, which means this had been going on far longer than the sixteen minutes I happened to be watching.

That is **pagein thrash**, and it is a memory symptom wearing a disk costume. The SSD was not failing. It was being asked to serve as RAM.

## Three ways `df` lied to me

Before I could see how full the disk was, I had to get past the tooling.

```
Filesystem      Size    Used   Avail Capacity   Mounted on
/dev/disk3s1s1  460Gi    12Gi    43Gi     22%   /
/dev/disk3s5    460Gi   396Gi    43Gi     91%   /System/Volumes/Data
```

**One.** Both rows show `460Gi` and `43Gi`. Not a coincidence and not a bug: APFS volumes share a single container. `Size` and `Avail` are container-wide and identical on every row. Only `Used` is per-volume. Never sum the rows.

**Two.** `df -h` reports GiB (1024³). `diskutil` and Finder report GB (1000³). The same 396 GiB shows as 425.5 GB. This is why `du` totals never reconcile with `df -h`.

**Three.** Finder counts "purgeable" space — snapshots and evictable caches — as free, because macOS *can* release it under pressure. `df` counts only genuinely free blocks. Finder will cheerfully claim 80 GB free while `df` says 20 GB, and under pressure reality behaves like `df`.

> **Takeaway.** One command tells the truth:
> ```
> diskutil info /System/Volumes/Data | grep "Container Free"
> ```

It said 36.6 GB free. **93% full.**

## The chain nobody diagnoses correctly

It starts with that lie of omission from Finder. You glance at storage, see 50 GB free, and assume you have breathing room — and because you have breathing room, you never look again.

A heavy polyglot toolchain doesn't just move gigabytes. It generates hundreds of thousands of tiny transient files — `~/.cache` alone held 107,760 of them. The disk creeps up over months, and nothing warns you, because 90% full still looks like plenty of room.

Then it stops being a storage problem and becomes a memory one:

```
disk fills past ~90%
      ↓
no headroom for snapshots, swap growth, or anything else
      ↓
RAM saturates; the compressor absorbs what it can
      ↓
page cache evicts executables and mmapped files
      ↓
they are re-read from SSD immediately   ← the sustained 18 MB/s
      ↓
kernel stalls on I/O → watchdog timeouts → jetsam kills your apps
```

Here is where I nearly published something I could not defend.

The tidy version is "the disk was too full for macOS to create a swapfile, so memory pressure had nowhere to go." I believed it for most of a day. **I cannot prove it.** There were 36.6 GB free — far more than the gigabyte a swapfile needs — and `swapouts: 0` for the whole boot means macOS never *attempted* to swap. The compressor was holding 9.4 GB of pages squeezed into 3.9 GB and was, technically, coping. I also never read the reason on that day's `JetsamEvent` before macOS rotated the file away, so I cannot tell you it was memory exhaustion rather than a routine per-process kill.

Steps 1 and 3 in that diagram are measured. The arrow between them is inference. Treat it as such.

> **Takeaway.** `vm.swapusage: total = 0.00M` means nothing on its own — plenty of machines run for weeks without touching swap. It is a signal only beside saturated RAM and a busy compressor, and even then it tells you the compressor is carrying the system, not that swap was refused. Judge memory pressure by pagein rate, compressor size and jetsam reasons. Never by "unused", which reads 259M on a perfectly healthy Mac.

## Deleting 9 GB and freeing nothing

I started clearing caches. Cleared 8.9 GB of Homebrew downloads. Re-checked free space.

It hadn't moved. Not "moved a little." Zero.

```
tmutil listlocalsnapshots /
com.apple.TimeMachine.2026-09-05-215646.local
```

A local Time Machine snapshot taken minutes earlier still referenced those blocks. Deleting the files removed the directory entries; the blocks stayed allocated. macOS mints these roughly hourly whenever Time Machine is on — including partway through your cleanup, re-pinning what you just deleted.

> **Takeaway.** Finish every cleanup with a thin, or it did nothing:
> ```
> sudo tmutil thinlocalsnapshots / 999999999999 4
> ```
> Those arguments matter. The number is how many bytes to try to free — deliberately absurd, meaning "all of them". The `4` is urgency, on a 1–4 scale, and 4 is the most aggressive: it will remove local snapshots rather than negotiate. These are *local* snapshots only; backups on your Time Machine destination are untouched. If you want a gentler pass, use urgency `1`.
>
> Better still: pause Time Machine for the duration so it cannot mint a fresh snapshot mid-run — and make sure whatever pauses it turns it back on. I left mine off for half an hour by hand, which is a lousy way to run a backup policy.

## The 460 GB file that was 42 GB

```
$ ls -lh Docker.raw
460G
$ du -h Docker.raw
 42G
```

`ls -lh` reports logical size. `Docker.raw` is sparse — 460 GB is the ceiling it may grow to, not what it occupies. Always `du` for disk images, VM bundles, and database files.

Then Docker Desktop did something I didn't expect. Its backend had been idle, and while I was poking at it, Resource Saver stopped the VM. I measured the file before and after: **42 GB → 22 GB**. Twenty gigabytes returned by an app shutting down.

I am describing a before and an after, not a mechanism I watched. Docker compacts the image at some point around a clean shutdown; whether that is TRIM passthrough, an explicit compaction step, or something else, I did not instrument it. What is reliable is the practical rule.

That taught me two things. Pruning frees space *inside* the VM; the host-side file shrinks only around a clean Docker Desktop shutdown, never from `docker system prune` alone. And the transient `500 Internal Server Error` responses I'd seen from the Docker API were teardown, not a wedged daemon. I had been one impatient `kill -9` away from leaving the VM's filesystem dirty — with my Postgres volumes inside it.

By the end of that night: **36.6 GB → 121.4 GB free.** Load average fell from 10.76 to 2.29. (It settles at 116.7 GB a day later, once the backup below has run and taken its own snapshots.)

---

## Then I checked when my last backup finished

This is the part I want you to act on.

Time Machine was on. It had always been on. System Settings said so.

```
SnapshotDates (completed backups):
  2026-05-24
  2026-06-09
  2026-07-04
  2026-07-05
  2026-07-06     ← last one
  ...nothing...
```

**Sixty-two days.** No completed backup since July 6, on a machine that showed "Time Machine: On" the entire time and never once told me otherwise.

The mechanism is the same root cause:

```
ReferenceLocalSnapshotDate = 2026-07-06 13:44:34
```

Time Machine keeps a local snapshot as the baseline it diffs against for incrementals. When the disk filled, macOS purged that snapshot's contents to reclaim space. It stayed in the list, marked `(dataless)` — present, but holding nothing. With no valid baseline, every subsequent backup failed. And retried. And failed.

Nine attempts on the final day alone, each burning CPU and I/O into the very pressure that caused it. `backupd` even tripped macOS's own CPU-resource reporter. None of it surfaced.

> **Takeaway.** "Enabled" and "working" are different questions. Check the age of the last *completed* backup:
> ```
> defaults read /Library/Preferences/com.apple.TimeMachine \
>   | sed -n '/SnapshotDates/,/);/p' | tail -3
> ```
> Read `SnapshotDates` (completions), not `AttemptDates` — the latter doesn't record every attempt, and I initially misread its gap as a two-month-longer outage than had actually occurred.
>
> Note this reads the preference file directly. `tmutil latestbackup` needs Full Disk Access, which a scheduled agent won't have.

## Two months later, my own check told me everything was fine

I want to spoil my own ending, because the second time is more instructive than the first.

I wrote that check. I put it in a launchd agent that runs every two hours. And on a later evening it told me, calmly and repeatedly:

```
OK    Backup     1d ago
```

It said that for thirty-three hours, across nineteen consecutive failed backups.

Same mechanism as before, one level up. `SnapshotDates` records the backups that *finish*. A chain that tries every hour and fails every hour doesn't make that number older — it makes it **stop**. And a number that has stopped is indistinguishable, for a full day, from a number that is fine. By the time it drifts past a two-day threshold, the destination is already two days behind.

The real signal was four lines away in the same file I was already reading:

```
RESULT = 26
```

Zero means the last attempt succeeded. Twenty-six is `BACKUP_FAILED_DISCONNECTED_NETWORK`. It had been sitting there the whole time.

> **Takeaway.** Age is a *lagging proxy* for "backups are working." Check the outcome of the most recent attempt too — same file, no extra privileges:
> ```
> defaults read /Library/Preferences/com.apple.TimeMachine | grep RESULT
> log show --last 24h --predicate 'subsystem == "com.apple.TimeMachine"' \
>   | grep BACKUP_FAILED
> ```

The cause turned out to be dull, which is the point. A laptop backing up to a NAS over Wi-Fi, closing its lid every few minutes, dropping the SMB session mid-copy every time. Fifty-eight of sixty reconnects landed within five seconds of a sleep transition. `backupd` does hold an anti-sleep assertion — but the kind that only blocks *idle* sleep. Closing the lid ignores it entirely.

Nothing was damaged. Time Machine aborts the attempt and retries cleanly, which is precisely why it never said a word. Seventy minutes with the lid open and it completed.

## The re-seed, and what it exposed

With the reference snapshot gone, Time Machine abandoned the broken chain and started over: **350 GB, 3.48 million files**, to a consumer NAS over Wi-Fi. It ran for ten and a half hours.

Watching it taught me the thing I'd have most liked to know a year ago.

Partway through, throughput collapsed from 22 MB/s to 1.4 MB/s while `backupd` sat at **173% CPU moving 7.5 files per second**. Not waiting on the network — grinding. Wi-Fi was pristine throughout: 802.11ax, −47 dBm, 1080 Mbps negotiated.

The cost wasn't bytes. It was **files**.

| Directory | Size | Files |
|---|---|---|
| `~/.ollama` | 6.6 GB | **29** |
| `~/Library/Containers/com.docker.docker` | 24.1 GB | **148** |
| `~/.pub-cache` | 1.2 GB | **61,296** |
| `~/.cache` | 8.8 GB | **107,760** |

`~/.ollama` is five times larger than `~/.pub-cache` and roughly two thousand times cheaper to back up. Big sequential blobs stream. Tiny files are a network round-trip each.

And you pay twice. Later, during the post-backup thinning pass, I watched it delete a superseded backup one `unlink` at a time over SMB — grinding through `~/.cache/uv/archive-v0/…`, the Python `uv` package cache. **Whatever you back up, you eventually pay to delete.**

None of that data was worth keeping. It's all reconstructible from a registry, a lockfile, or a re-download.

I excluded 75 GB across eleven directories — container images, package caches, toolchains — using sticky path exclusions so they survive the folders being deleted and recreated:

```bash
sudo tmutil addexclusion -p ~/.cache ~/.npm ~/.ollama ~/.rustup
```

The next incremental:

```
Total copied: 2455.05 MB      Avg speed: 192.91 MB/min
```

**About thirteen minutes, against ten and a half hours.**

That first one still carried some pre-exclusion state. Once the full list was
applied, the next four settled at **five to ten minutes** each — a routine
incremental to a consumer NAS over Wi-Fi, which is what it should have been all
along.

And afterwards, for the first time in the whole exercise:

```
vm.swapusage: total = 5120.00M  used = 3408.25M
```

The safety valve was working again.

I thought I had found one more culprit, and I want to include it because being
wrong here is instructive. Checking what held files open on the backup volume
turned up 92 handles belonging to `mds_store` — Spotlight, indexing an 819 GB
sparsebundle over SMB. Obvious waste, I decided: you have a whole backup browser,
why index it?

Two things corrected me. `mdutil -i off` on that volume does nothing useful — it
drops to `kMDConfigSearchLevelFSSearchOnly` and still reports `Indexing enabled`.
And System Settings refuses the exclusion outright:

> "Backups of …" is a Time Machine backup folder. You cannot add it to the
> privacy list.

Which is macOS telling you the index is deliberate. Nearly all those handles are
on `.Spotlight-V100/Store-V2` **on the destination**, and that index is what makes
the search field in Time Machine's browser work. It is the feature, not a leak.

> **Takeaway.** When the operating system actively prevents you from "fixing"
> something, treat that as evidence before treating it as an obstacle. I had a
> plausible mechanism, a real measurement, and the wrong conclusion — and the
> only thing that caught it was trying the fix and reading the refusal.

> **Takeaway.** Filter exclusion candidates by **file count**, not size. A 300 MB directory with 200,000 tiny files costs far more than 6 GB of model weights. And exclude subpaths deliberately — `~/.cargo/registry`, not `~/.cargo`, which holds credentials; `~/.m2/repository`, not `~/.m2`.

## What I built, and what it taught me about monitoring

Every signal was present for days beforehand. Jetsam events, macOS's own excessive-disk-write reports, free space falling. Nothing was watching.

So I wrote one. `plimsoll` is about a thousand lines of zsh with no runtime dependencies — a read-only diagnostic, a tiered reclaimer that is dry-run by default, and a launchd agent that checks every two hours and stays silent unless something changes.

The diagnostic ends with the answer rather than making you assemble it:

```
== Verdict ==
  OK    Disk       22% free
  OK    Backups    enabled
  OK    Backup     0d ago
  OK    Snapshots  2
  note  4 kernel report(s) in the last 3 days — none from memory exhaustion

OK    healthy
```

Every check in it exists because this incident hid behind the absence of it. The
backup-age check is the one I would install on someone else's machine unasked.

It also names what is in your backups that should not be, sorted by the metric
that actually costs — and hands you the command:

```
WARN  75.4 GB / 104,849 files of rebuildable data in every backup:
        24.1 GB        148 files  ~/Library/Containers/com.docker.docker
         8.8 GB    107,760 files  ~/.cache
         1.2 GB     61,296 files  ~/.pub-cache
      …
        sudo tmutil addexclusion -p …
```

That list is versioned in the repo, so a rebuilt machine gets the same policy from
one command instead of a memory of which caches were safe.

The interesting part wasn't the scripts, though. It was getting the *alerting*
right, and I got it wrong twice first.

**Mistake one: history escalating current state.** I treated jetsam reports as an alerting signal. After the disk was fixed, the guard kept reporting WARN for three days over kills that had already stopped — precisely when a monitor most needs to go quiet. Now there are two tiers: *checks* are current conditions and escalate; *notes* are historical context and never do.

**Mistake two: naming the wrong subsystem.** Every notification title was hardcoded `"Disk ${level}"` and the message body was built entirely from the disk branch. So the stale-backup alert announced itself as **"Disk CRIT: 22% free"** on a machine with 121 GB free — naming the wrong problem and contradicting its own threshold in the same sentence. Now each check owns its verdict and its wording, and the alert names the subsystem that's actually unhealthy.

**Mistake three: a check that could only ever answer "fine."** Not all `JetsamEvent`s mean the same thing — `per-process-limit` is routine, `vm-pageshortage` is real memory exhaustion — so the guard learned to read the reason. My first classifier used `sudo -n grep`, which fails whenever a password is required. It would have reported "no memory events" forever, and nothing would have distinguished that from the truth.

**Mistake four: I built the check out of the artifact of success.** This one took two months to surface, and it is the one I'd most want back. Backup *age* comes from the list of completed backups — so it only moves when the system is working. I had built a check that, by construction, could only ever report success, and then read its stillness as health. The fix was to add a second row reading the outcome of the last attempt, and to keep the two verdicts *separate*: "0 days old **and** failing" is the normal shape of that fault, and folding them into one number lets the healthy half hide the broken half.

> **Takeaway.** A check that reads *healthy* when it cannot tell is worse than no check. Report UNKNOWN. This bit me three separate times in one night, in three different scripts — and a fourth time, two months later, in the check I wrote to fix the problem this article is about.

## Who this actually affects

Honest scoping, because I don't think this is universal.

This bites when three conditions coincide: **a nearly-full disk, a slow backup destination, and a heavy polyglot toolchain.** Miss any one and you never see it.

- With 500 GB free, the swap valve never fails and none of this happens.
- With a fast local SSD as your destination, the file-count cost is still there — it's just ninety seconds instead of ten hours, so you never notice.
- Most developers never back up a dev machine at all beyond git and cloud sync, and quietly accept that a rebuild costs a day.

I'd been running all three conditions for months without knowing. The disk crept up, the backups died, and macOS never mentioned either.

But the second outage had **none** of them. Nineteen percent free, a healthy SSD, −59 dBm Wi-Fi with zero packet loss — and no completed backup for thirty-four hours. The laptop simply never stayed awake long enough in one stretch to finish one.

So the narrower claim is about disk pressure, and the wider one is this: a backup can be switched on, attempting on schedule, damaging nothing, and still not have worked in weeks. Disk pressure is one way to get there. A closed lid is another. What they share is that macOS reports the same thing in both cases, which is nothing at all.

### If it is memory, disk cleanup will not save you

Worth saying plainly, because everything above is about reclaiming space and that is only half an answer.

Freeing 85 GB gave the system headroom. It did not add RAM. On a 24 GB machine running an editor, a browser, a container runtime and a language server or three, the working set can simply exceed what you have — and then the compressor grinds, pageins climb, and no amount of `brew cleanup` touches it. The honest remedies for that are unglamorous: run fewer things at once, quit the container runtime when you are not using it, kill the second language server, or buy more RAM on the next machine.

Two numbers tell you which problem you have. If **pageins climb while pageouts stay near zero** and the compressor is large, that is a working set too big for the machine. If free space is low and snapshots are stacking up, that is the one this article can fix.

```bash
vm_stat | grep -E "Pageins|Pageouts"
```

Mine was both. Only one of them was fixable in a night.

## Five checks worth running right now

They take under a minute.

```bash
# 1. Real free space (not what df or Finder tell you)
diskutil info /System/Volumes/Data | grep "Container Free"
```
```bash
# 2. When did a backup last actually COMPLETE?
defaults read /Library/Preferences/com.apple.TimeMachine \
  | sed -n '/SnapshotDates/,/);/p' | tail -3
```
```bash
# 3. Did the LAST attempt succeed? 0 = yes, anything else is the failure code
defaults read /Library/Preferences/com.apple.TimeMachine | grep RESULT
```
```bash
# 4. Are snapshots holding space you think you freed?
tmutil listlocalsnapshots /
```
```bash
# 5. Is a cache in every one of your backups?
tmutil isexcluded ~/.cache
```

`[Included]` means yes, it is — along with however many hundreds of thousands of files it holds. Exclude it with `sudo tmutil addexclusion -p ~/.cache`.

One caution before you get enthusiastic with that command. Exclude **caches and registries**, not the directories that hold them: `~/.cargo/registry`, not `~/.cargo`, which also holds your credentials file; `~/.m2/repository`, not `~/.m2`, which holds `settings.xml`. And think twice about toolchain roots like `~/.rustup` or `~/.sdkman` — reconstructible in principle, but only if you have network and an afternoon. An exclusion is not a deletion, but it does mean that directory will not be there when you restore.

If #2 or #3 surprises you, this article did its job. #2 is the one people expect to be fine and is not. #3 is the one that stays wrong while #2 still looks right.

---

## Getting it

```bash
brew tap donco-labs/tap
brew trust --formula donco-labs/tap/plimsoll
brew install plimsoll
```

(Homebrew 6 refuses formulae from third-party taps until you trust them. The
formula is thirty lines and copies scripts into `libexec`; read it first, which is
the point of the gate.)

Then:

```bash
plimsoll report          # the diagnostic above
plimsoll install-guard   # the watchdog, every 2h
plimsoll reclaim         # dry-run; --apply to actually reclaim
```

Every destructive path is dry-run until you pass `--apply`, real data is reported
and never deleted, and pausing Time Machine is restored by a trap so an
interrupted run cannot leave a machine unbacked-up. It is macOS-only, it has been
proven on exactly one machine, and the exclusion list is tuned to my toolchain —
treat it as a starting point rather than gospel.

The repo's `docs/` directory carries the full postmortem: twelve lessons, each
naming which mistake produced which line of code, including the four theories that
turned out wrong. If you only read one, read the one about a monitor that reports
healthy when it cannot tell.

**[github.com/donco-labs/plimsoll](https://github.com/donco-labs/plimsoll)**
