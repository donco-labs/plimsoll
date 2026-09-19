# macOS disk creep: diagnose, clean, and stay clean

A field guide written from a real incident (see [POSTMORTEM.md](POSTMORTEM.md)):
a 24 GB MacBook Air hitting freezes and watchdog timeouts, with reads spiking
toward 1 GB/s and grinding at 18 MB/s sustained. The SSD was perfectly healthy. The disk being 93% full was the cause.

Read §1 to understand *why* the obvious tools mislead you. Skip to §3 if you
just need commands.

---

## 1. The five things that will fool you

### 1.1 `df` is not measuring what you think

```
Filesystem      Size    Used   Avail Capacity   Mounted on
/dev/disk3s1s1  460Gi    12Gi    43Gi     22%   /
/dev/disk3s5    460Gi   396Gi    43Gi     91%   /System/Volumes/Data
```

Both rows show `460Gi` and `43Gi`. That is not a coincidence and it is not a bug:
APFS volumes share a single **container**. `Size` and `Avail` are container-wide
and identical on every row; only `Used` is per-volume. Never add the rows up,
and never read `460Gi` as either volume's own quota.

**Use this instead** — the one number that is not lying:

```bash
diskutil info /System/Volumes/Data | grep "Container Free"
```

And when that command cannot answer — the volume is not mounted, the call is
sandboxed, the path is wrong — the honest report is *unknown*, not zero. The
toolkit says `free space unreadable` and raises WARN rather than CRIT: nothing
was measured, so no threshold was crossed. A monitor that turns a failed
measurement into `0% free` has invented the very emergency it exists to detect.

### 1.2 GiB vs GB

`df -h` reports GiB (1024³). `diskutil` and Finder report GB (1000³).

```
df:       Used 396 Gi
diskutil: Used 425.5 GB     ← identical byte count, ×1.0737
```

This is why `du` totals never reconcile with `df -h`. Nothing is missing.

### 1.3 Snapshots pin deleted files

**The single most confusing behaviour in this whole area.** Delete 9 GB. Watch
free space not move at all. The files are gone from the directory tree, but a
local Time Machine snapshot taken *before* the deletion still references those
blocks, so they stay allocated.

```bash
tmutil listlocalsnapshots /
```

Anything listed is holding space. Release it:

```bash
sudo tmutil thinlocalsnapshots / 999999999999 4
```

macOS mints these roughly hourly whenever Time Machine is enabled — including
partway through your cleanup, re-pinning what you just deleted. `reclaim.zsh`
handles this by pausing TM for the duration and thinning at the end.

**Thinning also removes Time Machine's incremental baseline.** `999999999999 4`
means "free as much as possible, highest urgency", and it means it: one run on
the host this toolkit came from took 14 snapshots to 0, freed 19 GB, and left
`ReferenceLocalSnapshotDate` pointing at a snapshot that no longer existed.

That is a fair trade when the chain is healthy. It is a bad one while backups are
already failing — you remove the baseline at the moment TM most needs it, which
is the mechanism behind the 62-day outage in [POSTMORTEM.md](POSTMORTEM.md), only
deliberate instead of accidental. How much extra work the next backup does as a
result was not measured.

`thin` and `reclaim --apply` refuse to run while a backup is in progress for the
same family of reason: thinning snapshots the running backup is reading from will
most likely abort it, and `reclaim` pauses TM with `tmutil disable`, which stops
it outright. Override with `PL_ALLOW_DURING_BACKUP=1` if you mean it.

### 1.4 Purgeable space (why Finder disagrees)

Finder and About This Mac count snapshots and evictable caches as free, because
macOS *can* release them under pressure. `df` counts only genuinely free blocks.
Finder will cheerfully claim 80 GB free while `df` says 20 GB. Under pressure,
reality behaves closer to `df`.

### 1.5 Sparse files (why `ls -lh` lies about Docker)

```bash
ls -lh Docker.raw     # 460G   ← the ceiling it may grow to
du -h  Docker.raw     #  42G   ← what is actually allocated
```

Always `du`. This applies to any disk image, VM, or database file.

---

## 2. Is it the disk, or is it the SSD?

Run SMART first so you can stop worrying about hardware:

```bash
sudo smartctl -a /dev/disk0
```

Five fields decide it:

| Field | Healthy | Meaning |
|---|---|---|
| `Critical Warning` | `0x00` | any nonzero = real trouble |
| `Available Spare` | 100% (thresh 99%) | retired-block reserve |
| `Percentage Used` | 0–90% | endurance consumed |
| `Media and Data Integrity Errors` | `0` | uncorrectable errors, ever |
| `Error Information Log Entries` | `0` | logged failures |

### Ignore this line

```
Read 1 entries from Error Information Log failed:
GetLogPage failed: system=0x38, sub=0x0, code=745
```

Benign, on every Apple Silicon Mac. Decoded: `system=0x38` is IOKit, `code=745`
is `kIOReturnDeviceError`. Apple's NVMe passthrough exposes **only** SMART/Health
log page `0x02`; smartctl also asks for Error Information page `0x01`, and the
driver refuses. The tell that it is a tool artifact: the log reports **0 entries**
and smartctl tries to read 1 anyway.

It also makes `smartctl` exit non-zero (4). Do not let that abort your scripts.

### Reading the lifetime counters

```
Data Units Read:     77,217,786 [39.5 TB]
Data Units Written:  27,033,148 [13.8 TB]
Power On Hours:      438
```

39.5 TB read over 438 hours is 90 GB/hour — which is **25 MB/s sustained**, every
hour the drive has been awake. Not a spike; a grind. No normal workload does
that. A read:write ratio near 3:1 at that rate is the signature of **pagein
thrash** — not disk wear. Which points at memory, not storage.

---

## 3. The actual failure mode

Here is the chain that produces "1 GB/s disk and the machine freezes":

```
disk fills past ~90%
        ↓
no headroom for snapshots, swap growth, or working space
        ↓
RAM pressure has no relief valve
        ↓
page cache evicts executables and mmapped files
        ↓
they are immediately re-read from SSD  ← the 1 GB/s
        ↓
kernel stalls on I/O → watchdog timeout → jetsam kills apps
```

Confirm each link:

```bash
sysctl vm.swapusage        # total = 0.00M while RAM is full = no relief valve
vm_stat | grep -E 'Pageins|Pageouts'   # pageins >> pageouts = read thrash
ls /Library/Logs/DiagnosticReports/ | grep -Ei 'jetsam|panic|watchdog'
```

**Key insight:** swap at zero is not itself a fault. Swap at zero *while RAM is
saturated and the disk is full* is the fault. Free the disk and the valve returns.

Note `PhysMem: 23G used, 259M unused` is **normal** on macOS — it uses all RAM as
cache. Judge pressure by jetsam events, compressor size, and swap behaviour, not
by "unused".

---

## 4. Reclaim, in order

Always dry-run first. Everything here is dry-run by default.

```bash
make report        # what is going on
make dry           # what tier 1+2 would free
make clean-safe    # tier 1: caches that regenerate silently
make clean-more    # tier 1+2: adds re-downloadable caches
make review        # tier 3: data — reported, never auto-deleted
```

### Tier 1 — regenerating caches, no user action to restore

| Target | Typical | Note |
|---|---|---|
| `~/Library/Developer/Xcode/iOS DeviceSupport` | **10–25 GB** | biggest safe win; regenerates on next device connect |
| Homebrew cache (`brew cleanup -s --prune=all`) | 5–10 GB | also clears its accumulated vendored Rubies |
| `~/Library/Developer/Xcode/DerivedData` | 3–10 GB | rebuilds |
| `~/Library/Caches/{go-build,JetBrains,pip,Yarn,node-gyp}` | 1–6 GB | all rebuild |

### Tier 2 — costs a re-download or rebuild

`~/.gradle/caches`, `~/Library/Caches/ms-playwright` (browser binaries),
`xcrun simctl delete unavailable`.

### Tier 3 — data. Decide by hand.

Local LLM models (`~/.ollama`, `~/models`), `~/Downloads`, alternative container
runtimes. The scripts **report** these and never delete them.

### Always end with a thin

`make clean-safe` does it for you. Manually:

```bash
sudo tmutil thinlocalsnapshots / 999999999999 4
```

Then read the real number:

```bash
diskutil info /System/Volumes/Data | grep "Container Free"
```

---

## 5. Docker

```bash
make docker         # report
make docker-clean   # prune + compact
```

### The volume landmine

**Never run `docker volume prune`.** A named volume shows as "dangling" the
moment its container is removed — but it still holds the data. Prune cannot
distinguish `myapp_postgres-data` from scratch space, and volumes are typically
a single-digit share of Docker's footprint anyway. `docker-reclaim.zsh` reports
unreferenced volumes, flags which have human-given names, and deletes none.

Removing a *container* also un-protects its image **and** its named volumes.

### Where the space actually is

```
Build Cache      10.85 GB   0 active   ← safest possible reclaim
Images 65 total  23.45 GB   16.67 GB reclaimable
  └─ repo:<none> entries are superseded layers from re-pulled tags
Volumes          9.76 GB    ← leave alone
```

### Pruning does not shrink `Docker.raw`

Pruning frees space *inside* the VM's filesystem. The host-side sparse file only
shrinks when Docker Desktop **compacts it on a clean shutdown**. In the source
incident this reclaimed 20 GB by itself (42 G → 22 G) with no prune at all.

So: prune, then quit Docker Desktop properly. If it still will not shrink,
Settings → Resources → Disk image size — which **recreates the image and
destroys every container, image and volume inside it**.

### Transient 500s are usually not a wedged daemon

```
500 Internal Server Error for API route .../v1.55/info
```

Docker Desktop's **Resource Saver** stops the VM after a few minutes idle. During
teardown the socket answers but every route 500s. That looks identical to a hang.
Wait a minute and re-check before reaching for `kill -9` — a hard kill can leave
the VM's filesystem dirty, and your database volumes live in there.

If you must kill it: `kill <pid>` (SIGTERM) on the top-level `com.docker.backend`,
wait 30 s, and only then escalate. Leave `com.docker.vmnetd` alone — it is a
launchd-managed privileged helper that respawns anyway.

---

## 6. The other half: I/O loops

Free disk alone will not fix sustained background I/O. Check for a
**cloud-sync ↔ Spotlight loop**:

Google Drive with `force_file_provider_materialization=on` downloads real bytes
on access. Spotlight indexes what appears. Indexing touches files. Drive
re-materializes. Round and round, at hundreds of MB/s.

Fix: System Settings → Spotlight → Search Privacy → **+** → add the **account
folder**, not just `My Drive`:

```
/Users/<you>/Library/CloudStorage/GoogleDrive-<account>
```

`My Drive` alone leaves `Other computers/` and `.shortcut-targets-by-id/`
indexed — often the larger half. `~/Library` is hidden in the picker; press
**⌘⇧G** and paste the path. Click **Done** — nothing commits until then.

Verify (`0` = excluded):

```bash
mdfind -onlyin ~/Library/CloudStorage/GoogleDrive-<account> -count "kMDItemFSName == '*'"
```

Other usual suspects: Time Machine running during the storm, duplicate language
servers (two `gopls` = 767 MB), and multiple container runtimes installed at once.

---

## 7. Staying clean

```bash
make install-guard    # launchd, checks every 2h, notifies on WARN/CRIT
make guard-status
make log
```

Thresholds default to 15% (warn) / 10% (critical). Override:

```bash
PL_WARN_PCT=20 PL_CRIT_PCT=12 make check
```

The guard also escalates on secondary signals: ≥5 local snapshots, Time Machine
left off, any jetsam/panic report in the last 3 days, and — the one that matters
most — **a stale backup chain**.

### "Enabled" is not "working"

Time Machine can fail silently for months. The mechanism:

```
disk fills
      ↓
macOS purges the local snapshot TM uses as its incremental reference
      ↓
that snapshot goes "(dataless)" — listed, but holding no data
      ↓
TM has no valid baseline to diff against → every backup fails
      ↓
backupd retries hard (CPU-resource diags), adding to the I/O storm
      ↓
nothing is surfaced to the user
```

On the host this toolkit came from, backups completed normally until
2026-07-06 and then stopped dead — **62 days with no completed backup**, while
Settings showed Time Machine happily "on". Nine failed attempts on the final day.

Read `SnapshotDates` (completions), not `AttemptDates`: the latter does not
record every attempt, and mistaking its gap for a completion gap overstates the
outage.

So the check is on the **age of the last completed backup**, not the on/off flag:

```bash
# Last completed backup — SnapshotDates, not AttemptDates
defaults read /Library/Preferences/com.apple.TimeMachine \
  | sed -n '/SnapshotDates/,/);/p' | tail -3
```

`AttemptDates` counts tries; `SnapshotDates` counts successes. Only the second
one means anything.

Thresholds `PL_TM_WARN_D` (2 days) and `PL_TM_CRIT_D` (7 days). A backup that is
*currently running* does not clear the alert — only a completed one does.

### Age is necessary, and not sufficient

That check has its own blind spot, and it is the same shape as the one it was
written to catch. `SnapshotDates` records completions, so a chain that attempts
hourly and fails every time does not age — it freezes. On the source host, 19
consecutive failures across 33 hours all reported:

```
OK    Backup     1d ago
```

Every attempt failed with `BACKUP_FAILED_DISCONNECTED_NETWORK (26)`. Nothing in
`SnapshotDates` could say so, because nothing completed.

So read the outcome of the most recent attempt as well. `RESULT` is `0` on
success and non-zero on failure, in the same world-readable plist:

```bash
# Outcome of the LAST attempt: 0 = success
defaults read /Library/Preferences/com.apple.TimeMachine | grep RESULT

# ...and what the failure actually was
log show --last 24h --predicate 'subsystem == "com.apple.TimeMachine"' \
  | grep BACKUP_FAILED
```

That is the `Last attempt` check: WARN on the first failing observation, CRIT after
`PL_TM_FAIL_CRIT_H` (12 hours). Age and outcome stay separate rows on purpose —
"0d ago **and** failing" is the normal shape of this fault, so folding them into
one verdict lets the healthy number hide the broken one.

### A healthy backup can still be mostly garbage

The other silent failure: the chain works fine, but most of what it copies is
reconstructible. Container images, package caches and toolchains get backed up
like anything else, inflating the byte count and — far worse for a network
destination — the **file count**, which is what actually costs.

On the source host, 75 GB across eleven directories was going to a NAS over
Wi-Fi. During the full re-seed `backupd` sat at **173% CPU moving 7.5 files/sec**:
not waiting on the network, but grinding sparsebundle band files over SMB.

`Docker.raw` is the standout — a single 22 GB sparse image rewritten on every
container run, so every *incremental* re-copies large chunks of it.

### File count, not byte count

On a network destination the **file count** is what costs. Every file is a
separate round-trip going in — and again later, one `unlink` at a time, when the
backup is thinned. Measured on the source host:

| Path | Size | Files |
|---|---|---|
| `~/.ollama` | 6.6 GB | **29** |
| `~/Library/Containers/com.docker.docker` | 24.1 GB | **148** |
| `~/.pub-cache` | 1.2 GB | **61,296** |
| `~/.cache` | 8.8 GB | **107,760** |

`~/.ollama` is five times larger than `~/.pub-cache` and roughly two thousand
times cheaper to back up. Filtering on size alone also hid `~/.cargo`
(233 MB, 15,705 files) and `~/Library/pnpm` (440 MB, 22,685) completely.

So the check flags on **either** axis — `PL_TM_MIN_BYTES` (500 MB) or
`PL_TM_MIN_FILES` (10,000) — and sorts by file count.

This showed up concretely during a post-backup thinning pass that sat in
`ThinningPostBackup` for tens of minutes at 0.9% CPU, deleting
`~/.cache/uv/archive-v0/...` entries one SMB round-trip at a time. Whatever you
back up, you eventually pay to delete.

`make report` lists what qualifies and emits a ready-to-paste command:

```bash
sudo tmutil addexclusion -p <paths>
```

`-p` makes the exclusion *sticky to the path*, so it survives the directory being
deleted and recreated — which is exactly what caches do. Verify with
`tmutil isexcluded <path>`; reverse with `sudo tmutil removeexclusion -p <path>`.

### Thresholds surface; the list is policy

`make report` uses size and file-count thresholds to decide what is worth your
attention *right now*. Those thresholds are the wrong basis for policy. A
freshly-emptied `DerivedData` is under threshold today and back to gigabytes next
week — on the source host exactly that happened, and both Xcode directories
silently stayed in every backup because they were empty at the moment the
exclusion command was generated.

So `bin/tm-exclude.zsh` applies to **every candidate that exists**, regardless of
current size, and `make tm-status` shows applied vs pending:

```bash
make tm-status          # 16 applied · 4 pending · 1 absent (of 21)
make tm-exclude         # dry run
make tm-exclude-apply   # apply
```

This keeps the report advisory (it still never changes anything) while giving the
policy a single, versioned, re-runnable home. `tmutil addexclusion` requires Full
Disk Access, so run it from a terminal that has it.

The candidate list (`PL_TM_EXCLUDE_CANDIDATES` in `lib/common.zsh`) deliberately
contains only things reconstructible from a registry, a lockfile, or a
re-download. Anything a person might have hand-curated — Documents, Downloads,
photo libraries — must never appear there, and the report asks you to review
rather than offering to apply the change itself.

This check is report-only, not in the guard: it is a one-time hygiene fix, and a
notification about it every two hours would be noise rather than signal.

Note `tmutil latestbackup` and `tmutil listbackups` require Full Disk Access,
which a LaunchAgent does not have. `/Library/Preferences/com.apple.TimeMachine.plist`
is world-readable, so the scripts read that instead and work unprivileged. When
the value cannot be read they report **UNKNOWN**, never OK — a check that reads
healthy when it cannot tell is worse than no check.

launchd rather than cron: launchd runs a missed interval on wake, so a sleeping
laptop still gets checked, and it runs in the GUI session that notifications need.

### Alerting policy

The guard *checks* every 2 hours but *notifies* only on a level change, or once
per `PL_RENOTIFY_H` (12) hours while a condition persists. Never on OK. A CRIT
nag every two hours for something you already know about trains you to ignore it.

### Checks vs notes

Every signal is one of two kinds, and conflating them produces false alarms:

| Tier | Meaning | Escalates? | Notifies? |
|---|---|---|---|
| **CHECK** | a current condition (disk %, backup age, snapshot count, TM on/off) | yes | yes |
| **NOTE** | historical context (jetsam/panic reports in the last 3 days) | **no** | **no** |

Jetsam reports are evidence that something *already happened*, not that anything
is wrong now. Left as an escalating signal they hold the guard at WARN for three
days after you fix the cause — precisely when a monitor most needs to go quiet.
If the cause is still live, disk % or backup age catches it as a current
condition, which is where it belongs.

Each check produces its own verdict; nothing mutates a shared level and no check
inherits another's wording. Overall level is the **worst** check, and the
notification names *that* subsystem:

```
Backup CRIT: 61 days stale
Disk CRIT: 8% free
Snapshots WARN: 7
```

The original design hardcoded `"Disk ${level}"` into every title and built the
message body entirely from the disk branch, so a 61-day-stale backup chain
announced itself as **"Disk CRIT: 22% free"** on a machine with 121 GB spare —
naming the wrong subsystem and contradicting its own threshold.

So a quiet notification tray is the expected steady state — `make log` is how you
confirm it is alive:

```bash
make log
```

The state file holds two independent facts: the last level *seen*, which always
updates and drives change detection, and the last time a notification actually
*fired*, which drives the repeat window. Keeping them in one field is a bug: a
`--quiet` run would silently consume a pending level change and the real
notification would never arrive.

---

## 8. Safety rules these scripts follow

1. **Dry-run by default.** Destructive paths require `--apply`.
2. **Never delete data**, only caches. Tier 3 is report-only, always.
3. **Never `docker volume prune`.**
4. **Time Machine is restored by a trap**, so an interrupted run cannot leave
   the machine unbacked-up.
5. **No `err_return`.** Diagnostic tools exit non-zero on benign conditions —
   `smartctl` returns 4 on the Apple GetLogPage artifact, `docker` fails when
   stopped, `du` on unreadable dirs. An early version of these scripts silently
   aborted halfway for exactly this reason.
