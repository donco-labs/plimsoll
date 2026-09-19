#!/usr/bin/env zsh
# common.zsh — shared helpers for plimsoll
# Sourced by every bin/*.zsh script. Not executable on its own.

emulate -L zsh
# NOTE: deliberately NOT err_return/pipe_fail. Diagnostic tools routinely exit
# non-zero on benign conditions (smartctl=4 on the Apple GetLogPage artifact,
# docker when stopped, du on unreadable dirs). Handle errors explicitly instead.
setopt no_err_return no_unset

# ---------------------------------------------------------------- constants --
# Where this library lives, captured at source time: inside a function $0 is the
# function's name, not the file's path.
: ${PL_LIB_DIR:=${0:A:h}}

: ${PL_DATA_VOLUME:=/System/Volumes/Data}
: ${PL_STATE_DIR:=$HOME/.local/state/plimsoll}
: ${PL_LOG:=$PL_STATE_DIR/plimsoll.log}

# Thresholds (percent of APFS container free). Override via env.
: ${PL_WARN_PCT:=15}
: ${PL_CRIT_PCT:=10}

# ------------------------------------------------------------------- colour --
if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  PL_RED=$'\e[31m'; PL_YEL=$'\e[33m'; PL_GRN=$'\e[32m'
  PL_DIM=$'\e[2m';  PL_BLD=$'\e[1m';  PL_RST=$'\e[0m'
else
  PL_RED=''; PL_YEL=''; PL_GRN=''; PL_DIM=''; PL_BLD=''; PL_RST=''
fi

pl_hdr()  { print -r -- ""; print -r -- "${PL_BLD}== $* ==${PL_RST}"; }
pl_ok()   { print -r -- "${PL_GRN}OK${PL_RST}    $*"; }
pl_warn() { print -r -- "${PL_YEL}WARN${PL_RST}  $*"; }
pl_crit() { print -r -- "${PL_RED}CRIT${PL_RST}  $*"; }
pl_info() { print -r -- "      $*"; }
pl_dim()  { print -r -- "${PL_DIM}$*${PL_RST}"; }

pl_log() {
  mkdir -p ${PL_LOG:h}
  print -r -- "$(date '+%Y-%m-%dT%H:%M:%S%z') $*" >> $PL_LOG
}

# --------------------------------------------------------------- disk truth --
# The ONLY number that is not lying to you.
#
# Why not `df`?
#   * APFS volumes share one container: `Size` and `Avail` are container-wide
#     and identical on every row. Only `Used` is per-volume. Never sum rows.
#   * `df -h` reports GiB (1024^3); diskutil and Finder report GB (1000^3).
#   * Finder counts "purgeable" (snapshots, evictable caches) as free. df does not.
#
# Failure is reported as failure. diskutil can fail to answer -- the volume is
# not mounted, the command is sandboxed, PL_DATA_VOLUME is wrong -- and the old
# behaviour was to print nothing and let pl_pct_free substitute a literal 0.
# "0% free" is a sentence about the disk, and it was being said when nothing had
# been measured at all: the Disk check read it as below every threshold and
# raised CRIT, so an unreadable volume looked exactly like a full one, notified
# as an emergency, and exited 2. These return non-zero and print nothing
# instead, and every caller is expected to say "unknown" rather than invent one.
pl_container_bytes() {  # $1 = "Free" | "Total" -> bytes, or non-zero if unreadable
  local field=${1:?Free|Total} v
  v=$(diskutil info $PL_DATA_VOLUME 2>/dev/null \
    | grep "Container ${field} Space" \
    | sed -E 's/.*\(([0-9]+) Bytes\).*/\1/')
  [[ $v == <-> ]] || return 1
  print -r -- $v
}

pl_free_bytes()  { pl_container_bytes Free }
pl_total_bytes() { pl_container_bytes Total }

pl_pct_free() {
  local free total
  free=$(pl_free_bytes)   || return 1
  total=$(pl_total_bytes) || return 1
  (( total > 0 ))         || return 1
  printf '%d' $(( free * 100 / total ))
}

# For the surfaces. Every one of them used to interpolate the raw helper, so an
# unreadable volume printed "( %)" or " B" depending on which one it reached.
pl_free_h() {
  local v
  if v=$(pl_free_bytes); then pl_human $v; else print -rn -- "unknown"; fi
}
pl_pct_free_h() {
  local v
  if v=$(pl_pct_free); then print -rn -- "${v}%"; else print -rn -- "unknown"; fi
}

pl_human() {  # bytes -> human (GB, base-10, to match diskutil/Finder)
  local b=${1:-0}
  if   (( b >= 1000000000 )); then printf '%.1f GB' $(( b / 1000000000.0 ))
  elif (( b >= 1000000    )); then printf '%.0f MB' $(( b / 1000000.0 ))
  else                             printf '%d B' $b
  fi
}

# `du` reports ALLOCATED blocks; `ls -lh` reports LOGICAL size. For sparse files
# (Docker.raw is the classic) those differ by tens of GB. Always du.
pl_size_of() {  # path -> allocated bytes (0 if missing)
  [[ -e $1 ]] || { print -r -- 0; return }
  du -sk "$1" 2>/dev/null | awk '{print $1 * 1024}'
}

pl_size_h() { pl_human $(pl_size_of "$1") }

# ---------------------------------------------------------------- snapshots --
# Deleting files that a local Time Machine snapshot references frees NOTHING
# until the snapshot is thinned. Always thin after a reclaim pass.
pl_snapshot_list()  { tmutil listlocalsnapshots / 2>/dev/null | grep -v '^Snapshots for' }
pl_snapshot_count() { pl_snapshot_list | grep -c . }

# Keep the newest local snapshot by default.
#
# `thinlocalsnapshots / 999999999999 4` is "free as much as possible, highest
# urgency", and it takes everything -- including the snapshot Time Machine uses
# as the baseline for its next incremental. Measured on the source host: 14
# snapshots to 0, 19 GB freed, and six hours later backupd logged
#
#   Failed to mount reference snapshot: com.apple.TimeMachine.2026-09-08-205130.local
#
# and had to establish what changed the expensive way. Older snapshots pin the
# most deleted data anyway, so keeping the newest costs a little space and saves
# the next backup real work. PL_THIN_ALL=1 restores the old behaviour.
: ${PL_THIN_ALL:=}

pl_thin_snapshots() {
  local -a snaps
  # Sorted, not trusting tmutil's output order: the names are
  # ...TimeMachine.YYYY-MM-DD-HHMMSS.local, so lexical order is chronological.
  snaps=( ${(f)"$(pl_snapshot_list | sort)"} )
  (( ${#snaps} )) || { pl_info "no local snapshots to thin"; return 0 }

  if [[ -n $PL_THIN_ALL ]]; then
    pl_info "thinning ALL local snapshots (external TM backups unaffected)…"
    sudo tmutil thinlocalsnapshots / 999999999999 4 2>&1 | sed 's/^/      /'
    return
  fi

  # Names look like com.apple.TimeMachine.2026-09-08-205130.local;
  # deletelocalsnapshots wants the bare YYYY-MM-DD-HHMMSS.
  local keep=${snaps[-1]} snap date
  pl_info "thinning $(( ${#snaps} - 1 )) local snapshot(s), keeping the newest"
  pl_info "keeping ${keep} — Time Machine's baseline for the next incremental"
  for snap in ${snaps[1,-2]}; do
    date=${${snap##*TimeMachine.}%.local}
    sudo tmutil deletelocalsnapshots "$date" 2>&1 | sed 's/^/      /'
  done
}

# ----------------------------------------------------------- Time Machine --
# "Is TM enabled" is NOT the same question as "is TM working". A backup chain can
# fail silently for months: if the disk fills, macOS purges the local snapshot TM
# uses as its incremental reference, the reference goes "(dataless)", and every
# subsequent backup fails with nothing surfaced to the user. That is exactly how
# this host went 2026-05-23 -> 2026-09-05 with no completed backup. Check AGE.
#
# Source: /Library/Preferences/com.apple.TimeMachine.plist is world-readable, so
# this works unprivileged under launchd. `tmutil latestbackup` does NOT -- it
# needs Full Disk Access, which a LaunchAgent will not have.
: ${PL_TM_WARN_D:=2}
: ${PL_TM_CRIT_D:=7}

# Hours a chain may keep failing before the verdict goes critical. Deliberately
# much tighter than PL_TM_CRIT_D: age is a lagging signal and a failing attempt
# is a live one, so it does not get a week's grace.
: ${PL_TM_FAIL_CRIT_H:=12}
: ${PL_TM_STATE:=$PL_STATE_DIR/tm.state}

pl_tm_running() { tmutil status 2>/dev/null | grep -q 'Running = 1' }

# Percent complete of the running backup, or empty if none / unreadable.
#
# tmutil reports a FRACTION, and early in a run it uses scientific notation --
# "2.466504299824327e-06" is a real value from a backup ten seconds old. Matching
# it with [0-9.]+ truncates at the exponent, so 0.0002% renders as 246.7%: a
# progress display that reads "246%" on a backup that has barely started.
#
# tmutil also reports -1 while a run has no measurable progress yet -- every
# preparation phase does it (HealthCheckFsck, MountingBackupVol,
# PreparingSourceVolumes), and a network destination can sit in one for
# minutes. Multiplied out that renders as "-100.0%". Treat it as the
# "do not know yet" sentinel it is and report no figure at all.
pl_tm_progress_pct() {
  local raw
  raw=$(tmutil status 2>/dev/null \
        | sed -nE 's/.*Percent"? = "([0-9.eE+-]+)".*/\1/p' | head -1)
  [[ -n $raw ]] || return 1
  [[ $raw == -* ]] && return 1
  printf '%.1f' $(( raw * 100 ))
}

# Epoch seconds of the last COMPLETED backup. Returns 1 if undeterminable --
# callers must report "unknown", never assume healthy. A check that silently
# reads OK when it cannot tell is worse than no check at all.
pl_tm_last_backup_epoch() {
  local d
  d=$(defaults read /Library/Preferences/com.apple.TimeMachine 2>/dev/null \
      | sed -n '/SnapshotDates/,/);/p' \
      | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} \+[0-9]{4}' \
      | tail -1)
  [[ -n $d ]] || return 1
  date -j -f '%Y-%m-%d %H:%M:%S %z' "$d" '+%s' 2>/dev/null
}

pl_tm_days_since_backup() {
  local e
  e=$(pl_tm_last_backup_epoch) || return 1
  [[ -n $e ]] || return 1
  print -r -- $(( ( $(date +%s) - e ) / 86400 ))
}

# ---- which build is this? ---------------------------------------------------
# Three sources, in order of authority:
#
#   1. PLIMSOLL_VERSION, if something set it.
#   2. The Homebrew Cellar path the entry point resolves through. This is the
#      version actually running rather than one baked in at build time, which
#      is what the formula installs.
#   3. `git describe` in a checkout. A checkout used to report a bare "dev",
#      which is true but useless the moment you point a live menu bar at your
#      working tree: "v0.4.4-1-gbe9cd7b-dirty" says which commit AND that there
#      are uncommitted edits, and the second half is the part you want when the
#      dropdown is not showing what you just wrote.
pl_version() {
  [[ -n ${PLIMSOLL_VERSION:-} ]] && { print -r -- "$PLIMSOLL_VERSION"; return }
  local self=${1:-${PL_ROOT:-${0:A:h}}} v
  v=$(print -r -- "$self" | sed -nE 's|.*/Cellar/plimsoll/([^/]+)/.*|\1|p')
  [[ -n $v ]] && { print -r -- "$v"; return }
  v=$(git -C "${self:h}" describe --tags --always --dirty 2>/dev/null)
  [[ -n $v ]] && { print -r -- "$v"; return }
  print -r -- dev
}

pl_tm_last_backup_human() {
  local e
  e=$(pl_tm_last_backup_epoch) || { print -r -- "unknown"; return 1 }
  date -r $e '+%Y-%m-%d %H:%M'
}

# Headline form of the same fact. "0d ago" collapsed five minutes and
# twenty-three hours into one string, while the Last attempt detail three lines
# below printed the exact timestamp -- the same fact at two precisions, with
# the coarse one in the more prominent place.
#
# A clock time is safe here because only the OK branch uses it, and that branch
# exists only while the backup is younger than PL_TM_WARN_D. Two days is the
# widest gap it ever has to describe, so a weekday is enough to disambiguate
# and no date is needed. The WARN and CRIT rows keep counting in days, which is
# what those rows are for.
pl_tm_last_backup_short() {
  local e; e=$(pl_tm_last_backup_epoch) || return 1
  # %Y%j, not %j: two different years share a day-of-year.
  if [[ $(date '+%Y%j') == $(date -r $e '+%Y%j') ]]; then
    date -r $e '+%H:%M'
  else
    date -r $e '+%a %H:%M'
  fi
}

# ---- how often is it MEANT to run? -----------------------------------------
# AutoBackupInterval is the configured cadence and is readable unprivileged.
# It is a target, not a schedule: macOS hands the actual firing to its activity
# scheduler, which defers on power, thermal state, network and what the user is
# doing. Measured gaps on one laptop against a 3600s setting ran 29 to 646
# minutes. So this reports the POLICY and nothing else -- a rendered "next
# backup at 21:51" would be wrong more often than right, and stating a time
# confidently and wrongly is the failure this toolkit was written about.
pl_tm_interval_human() {
  local v=$(defaults read /Library/Preferences/com.apple.TimeMachine AutoBackupInterval 2>/dev/null)
  [[ $v == <-> ]] || return 1
  (( v == 3600 )) && { print -r -- "hourly"; return 0 }
  (( v % 3600 == 0 )) && { print -r -- "every $(( v / 3600 ))h"; return 0 }
  (( v >= 60 ))       && { print -r -- "every $(( v / 60 ))m";   return 0 }
  print -r -- "every ${v}s"
}

# ---- what did the last backup actually move? -------------------------------
# backupd writes a per-pass summary at INFO level -- items added and the size of
# the whole backup, both logical and physical. Physical is the interesting one:
# it is what landed on the destination.
#
# Two hard limits shape this, and both are why it is cached rather than read:
#
#   Cost.      `log show --info` runs 1.0-1.4s. The menu bar renders every ten
#              minutes; paying that there would make the monitor a source of
#              the load it exists to watch for.
#   Retention. The info-level store keeps roughly 15 hours. Measured: a 3-day
#              window returns byte-identical output to a 12-hour one. So this
#              is blank precisely when backups have been failing for days --
#              which is exactly when it matters least, the Backup age row
#              having already gone CRIT by then.
#
# Cached against the backup it describes, not against a clock: one backup, one
# lookup, forever. A backup whose log has aged out is recorded as unavailable
# so the expensive query is not retried every two hours for data that is gone.
: ${PL_TM_LAST_CACHE:=$PL_STATE_DIR/tm-last.tsv}
: ${PL_TM_LOG_MAX_H:=15}

# Write the cache in one step. A render polls this file while the refresh is
# writing it (see pl_tm_last_stats_wait), and a plain ">" truncates first, so a
# poll landing in that window would read a half-written row and conclude the
# figures were unavailable. Rename is atomic; truncate-then-write is not.
pl_tm_last_cache_put() {
  local tmp=${PL_TM_LAST_CACHE}.$$
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" > $tmp 2>/dev/null \
    && mv -f $tmp $PL_TM_LAST_CACHE 2>/dev/null \
    || rm -f $tmp 2>/dev/null
}

# "1 hour, 47 minutes, 33.000 seconds" -> "1h47m"; "9.264 seconds" -> "9s".
# The menu bar has no room for prose and the seconds are noise on anything
# that ran for minutes.
#
# Pulled with grep rather than sed: a leading ".*" is greedy and swallows all
# but the last digit of the number it is supposed to be capturing, so "47
# minutes" captured as 7 and "11 minutes" as 1.
pl_tm_elapsed_short() {
  local t=$1 h m sec
  h=$(print -r -- "$t"   | grep -oE '[0-9]+ hour'                | grep -oE '^[0-9]+')
  m=$(print -r -- "$t"   | grep -oE '[0-9]+ minute'              | grep -oE '^[0-9]+')
  sec=$(print -r -- "$t" | grep -oE '[0-9]+(\.[0-9]+)? second'   | grep -oE '^[0-9]+')
  : ${h:=0} ${m:=0} ${sec:=0}
  if   (( h ));  then print -r -- "${h}h${m}m"
  elif (( m ));  then print -r -- "${m}m"
  else                print -r -- "${sec}s"
  fi
}

# backupd prints two decimals ("172.59 GB"), pl_human prints one ("108.8 GB").
# Both numbers land in the same dropdown, so round the log's to match rather
# than let the menu show two different conventions a line apart.
pl_tm_norm_size() {
  local v=$1
  [[ $v == <->.<->*' '* || $v == <->' '* ]] || { print -r -- "$v"; return }
  awk '{ printf (($1 == int($1)) ? "%d %s\n" : "%.1f %s\n"), $1, $2 }' <<< "$v"
}

# Expensive. Call from the guard, never from a render path.
pl_tm_last_stats_refresh() {
  local e; e=$(pl_tm_last_backup_epoch) || return 1
  mkdir -p ${PL_TM_LAST_CACHE:h}

  local age_h=$(( ( $(date +%s) - e ) / 3600 ))
  # Past the retention horizon there is nothing to find. Record that against
  # this backup so the query is not repeated for it.
  if (( age_h >= PL_TM_LOG_MAX_H )); then
    pl_tm_last_cache_put "$e" "" "" ""
    return 0
  fi

  # Window the query to the backup itself plus an hour of slack, so a machine
  # that backed up ten minutes ago does not scan fifteen hours of log.
  local win=$(( age_h + 1 ))
  local blob=$(/usr/bin/log show --last ${win}h --info \
      --predicate 'subsystem == "com.apple.TimeMachine" AND category == "CopyProgress"' \
      --style compact 2>/dev/null)

  # Last block wins. A backup copies each volume separately, and an interrupted
  # pass leaves its own summary behind above the one that finished.
  local added total elapsed
  added=$(print -r -- "$blob"   | grep -E 'Total Items Added'     | tail -1 | sed -nE 's/.*p: ([0-9.]+ [A-Za-z]+|Zero KB)\).*/\1/p')
  total=$(print -r -- "$blob"   | grep -E 'Total Items in Backup' | tail -1 | sed -nE 's/.*p: ([0-9.]+ [A-Za-z]+|Zero KB)\).*/\1/p')
  elapsed=$(print -r -- "$blob" | grep -E '^Time elapsed:'        | tail -1 | sed -nE 's/^Time elapsed: (.*)$/\1/p')
  added=$(pl_tm_norm_size "$added"); total=$(pl_tm_norm_size "$total")
  [[ -n $elapsed ]] && elapsed=$(pl_tm_elapsed_short "$elapsed")

  pl_tm_last_cache_put "$e" "$added" "$total" "$elapsed"
}

# How long a render may wait for a fresh backup's figures. Measured on this
# machine: `log show` costs 1.1-2.6s, and the window size barely moves it --
# most of it is a fixed startup, so a 1h query is no cheaper than a 15h one.
# Three seconds covers the slow end and gives up rather than hanging a render.
: ${PL_TM_STATS_WAIT_MS:=3000}

# Wait, briefly, for a refresh that is already running in the background.
#
# The refresh stays detached and the cost model is unchanged: blocking a render
# on `log show` every ten minutes would make the monitor a source of the load it
# exists to watch for. What makes a short wait affordable is that the cache is
# keyed to the BACKUP rather than to a clock, so a stale cache means a backup
# has completed since the last run. That is hourly at most, not every render --
# 24 waits a day against the 144 renders the original comment was rejecting.
#
# Without this the figures were simply absent from the first render after every
# backup. On an hourly cadence against a ten-minute plugin that left the Backup
# row sizeless for a whole render window every hour, and a reader who looked in
# that window -- roughly one look in six -- concluded the feature did not exist.
#
# Polls the cache rather than waiting on a pid: the refresh is launched fully
# detached, so there is nothing to wait(1) on, and it has to stay that way so
# the job still finishes and populates the cache when this gives up early.
pl_tm_last_stats_wait() {
  local e=$1 max=${2:-$PL_TM_STATS_WAIT_MS} waited=0 cached
  [[ -n $e ]] || return 1
  while (( waited < max )); do
    sleep 0.1
    (( waited += 100 ))
    [[ -r $PL_TM_LAST_CACHE ]] || continue
    IFS=$'\t' read -r cached _ < $PL_TM_LAST_CACHE
    # Keyed to this backup is the whole test. An empty "added" against a
    # matching key is the recorded "log has aged out" answer, which is final --
    # waiting longer for it would burn the full timeout on every render.
    [[ $cached == $e ]] && return 0
  done
  return 1
}

# True when the cache does not describe the backup that is currently the latest.
pl_tm_last_stats_stale() {
  local e; e=$(pl_tm_last_backup_epoch) || return 1
  [[ -r $PL_TM_LAST_CACHE ]] || return 0
  local cached; IFS=$'\t' read -r cached _ < $PL_TM_LAST_CACHE
  [[ $cached != $e ]]
}

# Headline form: "3.3 GB of 172.6 GB in 17m".
#
# The total was originally left to the detail line, which was a mistake: only
# non-OK rows render their detail, so on a healthy machine -- the normal case --
# the backup total was written into the JSON and displayed nowhere. The ratio is
# the whole point of showing the total, since it is what makes a backup legible
# as incremental rather than full, so it belongs where it is actually seen. It
# costs twelve characters on one row and no extra row at all.
pl_tm_last_short() {
  local stats added total elapsed
  stats=$(pl_tm_last_stats) || return 1
  IFS=$'\t' read -r added total elapsed <<< "$stats"
  [[ -n $added ]] || return 1
  print -rn -- "${added}${total:+ of ${total}}${elapsed:+ in ${elapsed}}"
}

# The sentence the checks append when the numbers are available. Empty string
# when they are not, so callers can interpolate it unconditionally.
#
# Added against total is also the full-vs-incremental answer, and a more honest
# one than the log's own "strategy:" line: 1.5 GB written into a 172.6 GB backup
# is self-evidently incremental, and needs no assumption about what an
# undocumented string means. A first backup writes essentially the whole thing,
# so the two numbers converge and the ratio says so without being told.
# The phrasing itself, lowercase and unpunctuated so each surface can place it
# in its own house style: the report opens its lines lowercase and ends them
# without a full stop, the tooltip needs a sentence. Kept in one place because
# it is one fact -- two copies of this string drift the moment either is edited.
pl_tm_last_sentence() {
  local stats added total elapsed
  stats=$(pl_tm_last_stats) || return 1
  IFS=$'\t' read -r added total elapsed <<< "$stats"
  [[ -n $added && -n $total ]] || return 1
  print -rn -- "wrote ${added} into a ${total} backup${elapsed:+ in ${elapsed}}"
}

pl_tm_last_clause() {
  local s; s=$(pl_tm_last_sentence) || return 0
  print -rn -- " ${(U)s[1]}${s[2,-1]}."
}
# NOTE: this used to reach a reader on the unhealthy path only, because visible
# detail rows are printed for problems. That stopped being true when the menu
# moved every row's detail into a tooltip: the healthy row's sentence is now one
# hover away, and this is what it says. The headline still carries
# pl_tm_last_short for the reader who never hovers, so the numbers survive
# either way.

# Cheap. Prints "<added>\t<total>\t<elapsed>" for the current last backup, or
# nothing at all -- an empty read is the normal state on a machine whose last
# backup predates the log, and callers simply omit the clause.
pl_tm_last_stats() {
  local e; e=$(pl_tm_last_backup_epoch) || return 1
  [[ -r $PL_TM_LAST_CACHE ]] || return 1
  local cached added total elapsed
  IFS=$'\t' read -r cached added total elapsed < $PL_TM_LAST_CACHE
  [[ $cached == $e && -n $added ]] || return 1
  printf '%s\t%s\t%s\n' "$added" "$total" "$elapsed"
}

# ---- did the last attempt actually SUCCEED? --------------------------------
# Age cannot see this, and that is the gap that lets a backup die quietly. The
# date above comes from SnapshotDates, which records completions only -- so a
# machine that attempts hourly and fails every single time simply freezes the
# number and keeps reporting "0d ago". By the time age drifts past PL_TM_WARN_D
# the destination is already days behind, and the guard was green throughout.
#
# RESULT is the outcome of the most recent attempt: 0 succeeded, non-zero
# failed. Same unprivileged `defaults read` the date comes from, which is the
# point -- the plist is not world-readable and `tmutil latestbackup` needs Full
# Disk Access, so under launchd this is the only route to the fact.
#
# One RESULT per configured destination, and the worst wins. On the single
# destination almost everyone has, that is exactly right; if you rotate between
# a NAS and a portable disk, read a failure as "at least one is failing", since
# the one sitting in a drawer will legitimately report stale.
pl_tm_last_result() {
  local r
  r=$(defaults read /Library/Preferences/com.apple.TimeMachine 2>/dev/null \
      | sed -nE 's/^[[:space:]]*RESULT[[:space:]]*=[[:space:]]*([0-9]+);.*/\1/p' \
      | sort -rn | head -1)
  [[ -n $r ]] || return 1
  print -r -- $r
}

# Only codes this toolkit has actually seen in
#   log show --predicate 'subsystem == "com.apple.TimeMachine"'
# are named. Everything else is reported as a bare number: a wrong cause sends
# you to the wrong subsystem, which is worse than an honest "look it up".
pl_tm_result_cause() {
  case ${1:-} in
    (26) print -r -- "network dropped mid-copy" ;;
    (31) print -r -- "backup disk locked" ;;
    (70) print -r -- "disk image detached mid-copy" ;;
    (*)  print -r -- "backupd error ${1:-?}" ;;
  esac
}

# How long it has been failing. RESULT says the last attempt failed; it cannot
# say whether that started an hour ago or last week, and that difference is the
# whole verdict. The unified log holds the history, but `log show` over a
# multi-day window costs seconds -- unacceptable in a check the menu bar polls
# every ten minutes -- and it rolls off anyway. So record the first failing
# observation and keep it.
#
# Keyed on the last-success date, not just on failure: when a backup finally
# lands, SnapshotDates advances, the anchor changes and the stamp is discarded.
# A later, unrelated failure then starts its own clock instead of inheriting an
# old one and jumping straight to CRIT.
pl_tm_failing_since() {  # $1 = anchor (last-success epoch, or "none")
  local anchor=${1:-none} prev="" since=""
  [[ -r $PL_TM_STATE ]] && IFS=$'\t' read -r prev since < $PL_TM_STATE
  if [[ $prev != $anchor || -z $since ]]; then
    since=$(date +%s)
    mkdir -p ${PL_TM_STATE:h}
    printf '%s\t%s\n' "$anchor" "$since" > $PL_TM_STATE
  fi
  print -r -- $since
}

pl_tm_failing_clear() { rm -f $PL_TM_STATE 2>/dev/null }

# Hold the clock at now, keeping the anchor. Used while the destination is out
# of reach: time spent away must not accumulate toward the CRIT threshold, or
# coming home to a single failed attempt would escalate instantly.
pl_tm_failing_reset() {
  mkdir -p ${PL_TM_STATE:h}
  printf '%s\t%s\n' "${1:-none}" "$(date +%s)" > $PL_TM_STATE
}

# Is the destination reachable from where this machine is right now?
#   0 reachable · 1 not reachable · 2 cannot tell
#
# Time Machine reports a laptop that is simply on the wrong network with the
# same BACKUP_FAILED_DISCONNECTED_NETWORK (26) it uses for a link that died
# mid-copy. It does not distinguish "your NAS is at home and you are not" from
# "your NAS is here and the transfer keeps breaking", so ask the network.
#
# Only ever called when the last attempt FAILED, so the cost lands on the
# abnormal path: measured 0.02s when the destination answers, a 1s ceiling when
# it does not. A healthy machine never pays it.
pl_tm_destination_reachable() {
  local info host mp
  info=$(tmutil destinationinfo 2>/dev/null) || return 2
  [[ -n $info ]] || return 2

  # A local disk is reachable exactly when it is mounted.
  if print -r -- "$info" | grep -q '^Kind[[:space:]]*:[[:space:]]*Local'; then
    mp=$(print -r -- "$info" | sed -nE 's/^Mount Point[[:space:]]*:[[:space:]]*(.+)$/\1/p' | head -1)
    [[ -n $mp ]] || return 2
    [[ -d $mp ]] && return 0 || return 1
  fi

  # Network. The URL carries a Bonjour SERVICE name, not a host name --
  # "MyCloudEX2Ultra._smb._tcp.local." does not resolve; strip the service
  # labels off it to get "MyCloudEX2Ultra.local", which does.
  host=$(print -r -- "$info" | sed -nE 's|^URL[[:space:]]*:[[:space:]]*[a-z]+://([^/]+)/.*|\1|p' | head -1)
  host=${host##*@}                    # drop any user@
  host=${host/._smb._tcp/}
  host=${host/._afpovertcp._tcp/}
  host=${host%.}                      # trailing dot from the Bonjour name
  [[ -n $host ]] || return 2
  ping -c 1 -t 1 "$host" >/dev/null 2>&1 && return 0 || return 1
}

pl_tm_enabled() {
  local v=$(defaults read /Library/Preferences/com.apple.TimeMachine AutoBackup 2>/dev/null)
  [[ $v == 1 ]]
}

# Pause TM so it cannot mint a fresh snapshot mid-reclaim and re-pin the blocks
# we are deleting. The trap guarantees it comes back on — leaving a machine
# without backups is far worse than a re-pinned cache.
PL_TM_WAS_ON=0
pl_tm_pause() {
  if pl_tm_enabled; then
    PL_TM_WAS_ON=1
    pl_info "pausing Time Machine for the duration…"
    sudo tmutil disable
    trap 'pl_tm_restore' EXIT INT TERM
  fi
}
pl_tm_restore() {
  if (( PL_TM_WAS_ON )); then
    PL_TM_WAS_ON=0
    print -r -- "      re-enabling Time Machine…"
    sudo tmutil enable
  fi
}

# ------------------------------------------------- Time Machine exclusions --
# A backup can be technically healthy and still be mostly garbage. Container
# images, package caches and toolchains are all reconstructible from a registry
# or a lockfile, but Time Machine copies them like anything else -- inflating
# both the byte count and, worse, the FILE count that dominates a network
# backup's cost. On the host this came from, ~60 GB of exactly this was going to
# a NAS over Wi-Fi, with backupd burning 173% CPU at 7.5 files/sec.
#
# Docker.raw deserves special mention: one 22 GB sparse image, rewritten on every
# container run, so every incremental re-copies large chunks of it.
#
# Only genuinely reconstructible paths belong here. Anything a user might have
# hand-curated (documents, Downloads, photo libraries) must never be suggested.
typeset -ga PL_TM_EXCLUDE_CANDIDATES=(
  ~/Library/Containers/com.docker.docker
  ~/Library/Application\ Support/com.apple.container
  ~/Library/Containers/com.inferencer
  # Claude Desktop's sandbox VM image. Same shape as Docker.raw: a handful of
  # huge files rewritten on every run, so each incremental re-copies a large
  # slice of 10 GB. The app recreates it; it holds runtime state, not documents.
  ~/Library/Application\ Support/Claude/vm_bundles
  ~/Library/Developer/Xcode/DerivedData
  ~/Library/Developer/Xcode/iOS\ DeviceSupport
  ~/Library/Caches
  ~/.cache
  ~/.gradle/caches
  ~/.npm
  ~/.ollama
  ~/.rustup
  ~/.konan
  ~/.sdkman
  ~/.pub-cache
  ~/fvm
  ~/go/pkg
  ~/Library/pnpm
  ~/.vscode/extensions
  ~/.cargo/registry
  ~/.m2/repository
)

# tmutil isexcluded prints "[Excluded]  /path" or "[Included]  /path".
# Works unprivileged, so this is safe from a LaunchAgent.
pl_tm_excluded() { tmutil isexcluded "$1" 2>/dev/null | grep -q '^\[Excluded\]' }

# On a network destination the FILE COUNT dominates, not the byte count: every
# file is a separate round-trip, on the way in and again when the backup is
# thinned. Measured on the source host: ~/.ollama is 6.6 GB in 29 files (cheap,
# big sequential blobs) while ~/.pub-cache is 1.2 GB in 61,296 files -- five
# times smaller, roughly two thousand times more round-trips. Filtering on size
# alone made ~/.cargo (233 MB, 15,705 files) and ~/Library/pnpm (440 MB, 22,685)
# invisible.
: ${PL_TM_MIN_BYTES:=500000000}
: ${PL_TM_MIN_FILES:=10000}

pl_file_count() { [[ -e $1 ]] && find "$1" 2>/dev/null | wc -l | tr -d ' ' || print -r -- 0 }

# Flag on EITHER axis.
pl_tm_worth_excluding() {  # $1 path, $2 bytes, $3 files
  (( $2 >= PL_TM_MIN_BYTES || $3 >= PL_TM_MIN_FILES ))
}

# ------------------------------------------------- kernel pressure events --
# Two traps here, both hit in practice:
#
# 1. DiagnosticReports contains a hidden `.contents.panic` metadata file. A bare
#    grep for "panic" counts it as a panic report, so the tally disagreed with
#    the list it printed (8 vs 7). Dotfiles are excluded.
#
# 2. Not all JetsamEvents mean the same thing. "per-process-limit" is one process
#    hitting its OWN ceiling -- routine, and not a sign of system trouble.
#    "vm-pageshortage" / "vm-thrashing" / "vm-compressor-*" are actual memory
#    exhaustion. Counting them together cries wolf over normal housekeeping.
pl_pressure_files() {  # $1 = days
  find /Library/Logs/DiagnosticReports -maxdepth 1 -mtime -${1:-3} \
       \! -name '.*' 2>/dev/null | grep -Ei 'jetsam|panic|watchdog|disk writes'
}

# Set by pl_pressure_events when a JetsamEvent could not be read and therefore
# could not be classified. Callers must surface this rather than treating an
# unreadable file as "not a memory event" -- a check that silently reads healthy
# when it cannot tell is worse than no check.
typeset -g PL_PRESSURE_UNKNOWN=0

pl_pressure_events() {  # $1 = days, $2 = "any" | "memory"
  local days=${1:-3} kind=${2:-any} f n=0
  if [[ $kind != memory ]]; then
    pl_pressure_files $days | grep -c . | tr -d ' '
    return
  fi
  PL_PRESSURE_UNKNOWN=0
  for f in ${(f)"$(pl_pressure_files $days)"}; do
    [[ $f == *JetsamEvent* ]] || continue
    # These are group-readable (_analyticsusers) on macOS 26, so no sudo -- and
    # deliberately NOT `sudo -n`, which fails whenever a password is required
    # and would silently make every event look benign.
    if ! grep -qE '"reason"' "$f" 2>/dev/null; then
      (( PL_PRESSURE_UNKNOWN++ )); continue
    fi
    grep -qE '"reason" : "(vm-pageshortage|vm-thrashing|vm-compressor)' "$f" 2>/dev/null && (( n++ ))
  done
  print -r -- $n
}

# ------------------------------------------------------------ health model --
# Each check yields its OWN verdict. Nothing mutates a shared level, and no
# check inherits another's prose -- the original design had every alert titled
# "Disk" and phrased in disk language, so a 61-day-stale backup chain announced
# itself as "Disk CRIT: 22% free" on a machine with 121 GB spare.
#
# Two tiers, deliberately distinct:
#   CHECKS  current conditions. Escalate, notify, set the exit code.
#   NOTES   historical context. Never escalate, never notify.
#
# Jetsam/panic reports live in NOTES on purpose. They are evidence that
# something already happened, not that anything is wrong now -- so after you fix
# the cause they would otherwise hold the guard at WARN for days, which is
# exactly when a monitor most needs to go quiet. If the cause is still live,
# disk% or backup age catches it as a current condition.

typeset -ga PL_CHECKS=()   # level \t name \t headline \t detail
typeset -ga PL_NOTES=()

# Set when the Last attempt row is failing only because the destination is out of
# reach. The row itself already says so, but a caller cannot tell that apart
# from any other WARN by reading the record, and the guard needs to: an expected
# weekday condition should not push a desktop notification. Matching on the
# headline string from outside would work until someone rewords it.
typeset -g PL_TM_AWAY=0

pl_check() { PL_CHECKS+=("${1}"$'\t'"${2}"$'\t'"${3}"$'\t'"${4:-$3}") }

# Accessors. The tab-separated record is an implementation detail; splitting it
# by hand at every call site duplicated the format five times and made the
# construct impossible to quote safely inside a CI `zsh -c '...'`.
pl_check_level()    { print -r -- "${1%%$'\t'*}" }
pl_check_name()     { print -r -- "$1" | cut -f2 }
pl_check_headline() { print -r -- "$1" | cut -f3 }
pl_check_detail()   { print -r -- "$1" | cut -f4 }
pl_note()  { PL_NOTES+=("$1") }

pl_level_rank() { case $1 in (CRIT) print -r -- 2 ;; (WARN) print -r -- 1 ;; (*) print -r -- 0 ;; esac }

# Worst check wins. Returns the whole record so callers can name the subsystem.
pl_worst_check() {
  # best starts below the lowest rank so an all-OK run still names a subject;
  # otherwise nothing is ever selected and callers get an empty record.
  local c best=-1 r winner=""
  for c in $PL_CHECKS; do
    r=$(pl_level_rank $(pl_check_level $c))
    (( r > best )) && { best=$r; winner=$c }
  done
  print -r -- $winner
}

pl_overall_level() {
  local w=$(pl_worst_check)
  [[ -n $w ]] && pl_check_level $w || print -r -- OK
}

# Populates PL_CHECKS / PL_NOTES. Single source of truth: the report and the
# guard must never disagree about whether this machine is healthy.
pl_run_health_checks() {
  PL_CHECKS=(); PL_NOTES=(); PL_TM_AWAY=0

  # -- disk --------------------------------------------------------------
  # The percentage answers "is this a problem"; the absolute figure answers "how
  # much room do I have", and people want both -- so both go in the headline,
  # which is the one string every surface shows: the Verdict row, the menu bar
  # dropdown and the notification title. The detail is then free to say only
  # what it is for, which is what happens next. It used to restate the same two
  # numbers, and once the headline carried them the menu bar printed them twice
  # on adjacent rows.
  local free pct
  if ! { free=$(pl_free_bytes) && pct=$(pl_pct_free) }; then
    # WARN, not CRIT, and the same shape as the Backup check's "age unknown":
    # not knowing is a state to fix, not a disk emergency to be woken for.
    pl_check WARN Disk "free space unreadable" \
      "diskutil could not report container space for ${PL_DATA_VOLUME} — unverified, not healthy. Nothing was measured, so no threshold was crossed; check that the volume is mounted and that diskutil answers."
  else
    local disk_h="${pct}% free ($(pl_human $free))"
    if   (( pct < PL_CRIT_PCT )); then
      pl_check CRIT Disk "$disk_h" "Swap cannot grow — expect freezes and app kills."
    elif (( pct < PL_WARN_PCT )); then
      pl_check WARN Disk "$disk_h" "Reclaim before it bites."
    else
      pl_check OK   Disk "$disk_h" "$(pl_human $free) free of $(pl_human $(pl_total_bytes)). Warns below ${PL_WARN_PCT}%, critical below ${PL_CRIT_PCT}%."
    fi
  fi

  # -- backups on at all -------------------------------------------------
  local tm_on=0
  if pl_tm_enabled; then
    tm_on=1
    # The cadence rides here because "enabled" alone never answers the question
    # people actually have, which is how often. It is the configured policy, not
    # a promise about when the next one fires -- see pl_tm_interval_human.
    local iv=$(pl_tm_interval_human) && [[ -n $iv ]] || iv=""
    pl_check OK Backups "enabled${iv:+ · $iv}" "Automatic backups are on${iv:+, running $iv}. That is the configured cadence, not a promise about when the next one fires."
  else
    pl_check CRIT Backups "off" "Automatic backups are off — nothing is being backed up."
  fi

  # -- backup chain actually completing ----------------------------------
  local d
  if d=$(pl_tm_days_since_backup); then
    if   (( d >= PL_TM_CRIT_D )); then
      pl_check CRIT Backup "last good ${d} days ago" "Nothing has completed since $(pl_tm_last_backup_human)."
    elif (( d >= PL_TM_WARN_D )); then
      pl_check WARN Backup "last good ${d} days ago" "Last one finished $(pl_tm_last_backup_human)."
    else
      # Only the healthy row gets the size. A stale chain has a more urgent
      # thing to say, and past PL_TM_LOG_MAX_H the figure is gone anyway.
      local short=$(pl_tm_last_short)
      local when; when=$(pl_tm_last_backup_short) || when="${d}d ago"
      pl_check OK Backup "${when}${short:+ · $short}" \
        "Last completed backup $(pl_tm_last_backup_human).$(pl_tm_last_clause)"
    fi
  else
    pl_check WARN Backup "age unknown" "Could not read the last backup date — unverified, not healthy."
  fi

  # -- are those attempts succeeding -------------------------------------
  # Age and outcome are different facts and get different rows. A chain can be
  # "0d ago" and failing every hour -- that is the normal shape of this fault,
  # not an edge case -- so folding the two together would let the healthy number
  # mask the broken one. Skipped when Time Machine is off: the CRIT above
  # already says nothing is being backed up, and a stale RESULT adds no signal.
  if (( tm_on )); then
    local res
    if res=$(pl_tm_last_result); then
      if (( res == 0 )); then
        pl_tm_failing_clear
        pl_check OK "Last attempt" "ok"
      else
        local anchor since hours cause reach
        anchor=$(pl_tm_last_backup_epoch) || anchor=none
        cause=$(pl_tm_result_cause $res)
        pl_tm_destination_reachable; reach=$?

        # Being away from the destination is not a fault. A laptop on a
        # different network cannot reach the NAS at home, and Time Machine
        # reports that with the same code 26 a genuine mid-copy drop produces.
        #
        # It stays a WARN, because backups are genuinely not happening and a
        # check that reads OK because you are travelling is the same lie this
        # toolkit exists to catch. What it does not do is escalate: the Backup
        # age check above already owns "away too long", and duplicating that
        # here would put two rows at CRIT for one condition.
        #
        # Only a definite "not reachable" (1) suppresses escalation. A probe
        # that cannot tell (2) takes the normal path -- never go quiet on
        # uncertainty.
        if (( reach == 1 )); then
          # Hold the clock, or coming home to one failed attempt would escalate
          # instantly on time that was only ever spent out of range.
          pl_tm_failing_reset $anchor
          PL_TM_AWAY=1
          pl_check WARN "Last attempt" "destination not reachable" \
            "Destination unreachable from this network (code ${res}). Expected while away; clears on its network. If you stay away, the Backup row is what escalates."
        else
          since=$(pl_tm_failing_since $anchor)
          hours=$(( ( $(date +%s) - since ) / 3600 ))
          if (( hours >= PL_TM_FAIL_CRIT_H )); then
            pl_check CRIT "Last attempt" "failed — ${cause}" \
              "Failing ${hours}h — ${cause} (code ${res}). Destination is reachable, so not distance."
          else
            pl_check WARN "Last attempt" "failed — ${cause}" \
              "Last attempt failed — ${cause} (code ${res}). The age above only moves on success."
          fi
        fi
      fi
    else
      pl_check WARN "Last attempt" "unknown" \
        "Could not read the last attempt's outcome — unverified, not healthy."
    fi
  fi

  # -- snapshots holding space -------------------------------------------
  # Headline stays a bare count: it is rendered as "Snapshots: 5" in the menu
  # bar, where every character costs. "Pinning" was also invented jargon.
  local n=$(pl_snapshot_count)
  if (( n >= 5 )); then
    pl_check WARN Snapshots "${n}" \
      "${n} snapshots hold space from deleted files. Deleting more frees nothing until they are thinned."
  else
    pl_check OK Snapshots "${n}" "${n} local snapshot(s). They hold space from deleted files; this warns at 5."
  fi

  # -- historical context, never escalates -------------------------------
  local n_mem=$(pl_pressure_events 3 memory) n_any=$(pl_pressure_events 3 any)
  if (( n_mem > 0 )); then
    pl_note "${n_mem} memory-exhaustion event(s) in 3 days — if it recurs, look at RAM not disk"
  elif (( PL_PRESSURE_UNKNOWN > 0 )); then
    pl_note "${PL_PRESSURE_UNKNOWN} jetsam event(s) in 3 days, reason unreadable"
  elif (( n_any > 0 )); then
    pl_note "${n_any} kernel report(s) in 3 days — none from memory exhaustion"
  fi
}

# --------------------------------------------------------------- watchlist --
# Directories worth watching for creep. A SUPERSET of the exclusion candidates:
# it includes user data like ~/Downloads that should be watched but must never
# be suggested for exclusion, so the two lists stay separate on purpose.
typeset -ga PL_WATCH_PATHS=(
  $PL_TM_EXCLUDE_CANDIDATES
  ~/Downloads
  ~/models
  ~/.gradle
  ~/Library/Developer/Xcode
)

# What would act on each watched directory, so the menu can say so. The value
# names a reclaim group -- clean-safe is `plimsoll reclaim`, clean-more is
# `--tier 2`, docker-clean is `plimsoll docker` -- or "yours" for data
# nothing automated will ever touch. The callers spell the command out; the make
# targets of the same name are clone-only wrappers over those same invocations.
# "/part" marks a directory where only a subtree is reclaimed, the common case
# -- ~/Library/Caches is watched whole, but tier 1 removes eight named children
# of it, so labelling the row "clean-safe" flat would promise the whole 6 GB.
#
# This is a table rather than something derived from reclaim.zsh because those
# rules are globs, mtime filters and tool invocations (`brew cleanup`, `uv cache
# prune`), not a list of paths. The cost of a table is drift, so `make lint`
# fails when a watched path has no entry here or an entry names a path that is
# no longer watched. Keep it in step with bin/reclaim.zsh by hand.
typeset -gA PL_WATCH_TARGET=(
  # tier 1 -- make clean-safe
  "$HOME/Library/Developer/Xcode"                          "clean-safe/part"
  "$HOME/Library/Caches"                                   "clean-safe/part"
  "$HOME/Library/pnpm"                                     "clean-safe/part"
  "$HOME/.npm"                                             "clean-safe/part"
  # tier 2 -- make clean-more
  "$HOME/.gradle"                                          "clean-more/part"
  # containers, which neither tier touches
  "$HOME/Library/Containers/com.docker.docker"             "docker-clean"
  # tier 3 and unclassified: reported, never automated
  "$HOME/Library/Application Support/com.apple.container"  "yours"
  "$HOME/Library/Application Support/Claude/vm_bundles"    "yours"
  "$HOME/Library/Containers/com.inferencer"                "yours"
  "$HOME/Downloads"                                        "yours"
  "$HOME/models"                                           "yours"
  "$HOME/.ollama"                                          "yours"
  "$HOME/.cache"                                           "yours"
  "$HOME/.rustup"                                          "yours"
  "$HOME/.konan"                                           "yours"
  "$HOME/.sdkman"                                          "yours"
  "$HOME/.pub-cache"                                       "yours"
  "$HOME/fvm"                                              "yours"
  "$HOME/go/pkg"                                           "yours"
  "$HOME/.vscode/extensions"                               "yours"
  "$HOME/.cargo/registry"                                  "yours"
  "$HOME/.m2/repository"                                   "yours"
)

pl_watch_target() {  # path -> "<reclaim group>[/part]" or "yours"
  print -r -- ${PL_WATCH_TARGET[$1]:-yours}
}

# Fails when the table above and the watch list have drifted apart. Run by
# `make lint`, because the failure mode otherwise is a menu row quietly
# promising that `make clean-safe` will empty a directory it never touches.
pl_watch_target_lint() {
  local p rc=0
  local -a watched=(${(f)"$(pl_watch_paths_effective)"})
  for p in $watched; do
    [[ -n ${PL_WATCH_TARGET[$p]:-} ]] || { print -ru2 -- "  watch path with no target: ${p/#$HOME/~}"; rc=1 }
  done
  for p in ${(k)PL_WATCH_TARGET}; do
    (( ${watched[(Ie)$p]} )) || { print -ru2 -- "  target for unmeasured path: ${p/#$HOME/~}"; rc=1 }
  done
  (( rc )) || print -r -- "  ok  watch targets (${#PL_WATCH_TARGET} paths)"
  return $rc
}

# Sizing this set costs ~10s of directory walking — fine twice a day, absurd
# every ten minutes. A menu bar item that generated sustained metadata I/O would
# be causing the exact problem this toolkit exists to detect. So: cache it, and
# refresh only when stale. Creep happens over days; half-day-old numbers are
# entirely adequate for spotting it.
: ${PL_SIZES_CACHE:=$PL_STATE_DIR/sizes.tsv}
: ${PL_SIZES_MAX_AGE_H:=12}

pl_sizes_age_hours() {
  [[ -r $PL_SIZES_CACHE ]] || { print -r -- 9999; return }
  local m=$(stat -f %m "$PL_SIZES_CACHE" 2>/dev/null)
  [[ -n $m ]] && print -r -- $(( ( $(date +%s) - m ) / 3600 )) || print -r -- 9999
}

pl_sizes_stale() { (( $(pl_sizes_age_hours) >= PL_SIZES_MAX_AGE_H )) }

# Writes "<bytes>\t<path>" for everything that exists, biggest first.
# The watch list with nested entries dropped -- ~/.gradle/caches under
# ~/.gradle, DerivedData under ~/Library/Developer/Xcode. Without this the child
# is counted twice in the total and both rows appear in the list, which reads as
# though the space is in two places. This is what actually gets measured, so it
# is also the set the target table is linted against.
pl_watch_paths_effective() {
  local -a keep=()
  local a b nested
  for a in ${(o)PL_WATCH_PATHS}; do
    nested=0
    for b in $keep; do [[ $a == ${b}/* ]] && { nested=1; break } ; done
    (( nested )) || keep+=($a)
  done
  print -rl -- $keep
}

pl_sizes_refresh() {
  mkdir -p ${PL_SIZES_CACHE:h}
  local tmp=${PL_SIZES_CACHE}.$$
  local c sz

  # One walk at a time. The guard launches this detached every two hours and a
  # cold walk over ~22 trees outlasts that interval on a loaded machine, so runs
  # overlap. That is not merely wasted IO: each racer mv's its own cache into
  # place and then stamps a history sample with whatever mtime it reads back, so
  # two landing together record the SAME epoch twice. pl_sizes_total_series sums
  # per timestamp, so the total is multiplied by the number of racers -- a
  # steady 113 GB watch set once reported a 226 GB drop, because the older
  # sample had been written three times and the newer one once. Per-path rows
  # hide it: the duplicates carry identical values, so their deltas stay right.
  local lock=${PL_SIZES_CACHE:h}/refresh.lock
  if ! mkdir $lock 2>/dev/null; then
    # A killed walk leaves the directory behind. Nothing legitimate holds it for
    # an hour, so treat anything older as debris rather than as a live run.
    local lage=$(( $(date +%s) - $(stat -f %m $lock 2>/dev/null || print -r -- 0) ))
    (( lage < 3600 )) && return 0
    rm -rf $lock 2>/dev/null
    mkdir $lock 2>/dev/null || return 0
  fi

  # An interrupted refresh -- the guard backgrounds this and the machine sleeps,
  # or a walk is killed -- used to leave its scratch file behind in the state
  # directory forever. zsh scopes a trap set inside a function to that function.
  trap "rm -f ${(q)tmp}; rmdir ${(q)lock} 2>/dev/null" EXIT INT TERM

  local -a keep=(${(f)"$(pl_watch_paths_effective)"})
  for c in $keep; do
    [[ -e $c ]] || continue
    sz=$(pl_size_of $c)
    (( sz > 0 )) && printf '%s\t%s\n' "$sz" "$c"
  done | sort -rn > $tmp
  mv -f $tmp $PL_SIZES_CACHE

  # Same numbers, kept rather than overwritten, so the next read can say which
  # way each directory is moving. Appended after the cache is in place: a
  # history sample nothing can corroborate is worse than none.
  pl_sizes_history_append "$(stat -f %m $PL_SIZES_CACHE 2>/dev/null)" < $PL_SIZES_CACHE
  pl_sizes_history_prune
}

pl_sizes_read() { [[ -r $PL_SIZES_CACHE ]] && cat $PL_SIZES_CACHE }

# A point-in-time size tells you what a directory holds; only a series tells you
# whether it is growing, which is the question the watchlist exists to answer.
# sizes.tsv is overwritten on every refresh, so each measurement is also
# appended here: "<epoch>\t<bytes>\t<path>", oldest first. At two refreshes a
# day over ~22 paths that is a couple of KB a day, and it is pruned to
# PL_SIZES_HISTORY_DAYS, so the file settles well under a megabyte.
: ${PL_SIZES_HISTORY:=$PL_STATE_DIR/sizes-history.tsv}
: ${PL_SIZES_HISTORY_DAYS:=180}
# A week reads well at a twice-daily cadence: ~14 samples, long enough that a
# single large download does not dominate, short enough to still be news.
: ${PL_TREND_WINDOW_D:=7}
# du rounds, caches breathe, and a browser writing a few MB is not creep. Deltas
# below this are reported as steady rather than as movement.
: ${PL_TREND_NOISE:=52428800}          # 50 MB

pl_sizes_history_append() {  # $1 = sample epoch (default now) · stdin "<bytes>\t<path>"
  local now=${1:-$(date +%s)} b pth
  mkdir -p ${PL_SIZES_HISTORY:h}
  # Idempotent on the epoch. The refresh lock above is the real defence against
  # a doubled sample, but this file is the only record of what the machine was
  # doing months ago -- there is no recomputing it -- so it refuses a second
  # write under a timestamp it already holds rather than trusting the caller.
  if [[ -r $PL_SIZES_HISTORY ]] &&
     awk -F'\t' -v e="$now" '$1 == e { f = 1; exit } END { exit !f }' $PL_SIZES_HISTORY
  then
    return 0
  fi
  while IFS=$'\t' read -r b pth; do
    [[ -n $b && -n $pth ]] && printf '%s\t%s\t%s\n' "$now" "$b" "$pth"
  done >> $PL_SIZES_HISTORY
}

pl_sizes_history_prune() {
  [[ -r $PL_SIZES_HISTORY ]] || return 0
  local cutoff=$(( $(date +%s) - PL_SIZES_HISTORY_DAYS * 86400 ))
  local tmp=${PL_SIZES_HISTORY}.$$
  trap "rm -f ${(q)tmp}" EXIT INT TERM
  awk -F'\t' -v c=$cutoff '$1 >= c' $PL_SIZES_HISTORY > $tmp && mv -f $tmp $PL_SIZES_HISTORY
}

# Samples for one path, oldest first, in the same "<epoch> <bytes>" shape
# pl_sparkline and pl_series_delta read. The file is appended in time order, so
# no sort is needed.
pl_sizes_series() {  # $1 = path · $2 = days (default PL_TREND_WINDOW_D)
  [[ -r $PL_SIZES_HISTORY ]] || return 1
  local cutoff=$(( $(date +%s) - ${2:-$PL_TREND_WINDOW_D} * 86400 ))
  awk -F'\t' -v c=$cutoff -v p="$1" '$1 >= c && $3 == p { print $1, $2 }' $PL_SIZES_HISTORY
}

# Signed byte delta between the oldest and newest sample on stdin. Non-zero exit
# when there is no baseline yet, which is the honest answer for the first week
# after this ships and for any directory that has only just appeared.
pl_series_delta() {  # reads "<epoch> <bytes>" lines on stdin
  local -a b; local ts by
  while read -r ts by; do b+=($by); done
  (( ${#b} < 2 )) && return 1
  print -r -- $(( b[-1] - b[1] ))
}

pl_sizes_delta() {  # $1 = path · $2 = days -> signed bytes, or non-zero exit
  pl_sizes_series "$1" ${2:-$PL_TREND_WINDOW_D} | pl_series_delta
}

# The watch set as one number per measurement. Every path is stamped with the
# same epoch by a refresh, so summing per timestamp gives the total's own series
# -- which is what the footer needs. Derived here rather than by adding up the
# per-path deltas, so it includes the directories too small to earn a row.
pl_sizes_total_series() {  # $1 = days (default PL_TREND_WINDOW_D)
  [[ -r $PL_SIZES_HISTORY ]] || return 1
  local cutoff=$(( $(date +%s) - ${1:-$PL_TREND_WINDOW_D} * 86400 ))
  # One row per (epoch, path): a history written before the refresh lock existed
  # can still hold a sample twice, and summing it raw multiplies the total.
  awk -F'\t' -v c=$cutoff '$1 >= c && !seen[$1 FS $3]++ { s[$1] += $2 } END { for (t in s) print t, s[t] }' \
    $PL_SIZES_HISTORY | sort -n
}

# Arrows rather than +/- because the row is scanned, not read: direction should
# survive peripheral vision. Movement under the noise floor is not an arrow.
pl_human_delta() {  # signed bytes -> "^1.2 GB" / "v1.2 GB" / "steady"
  local d=${1:-0}
  if   (( d >=  PL_TREND_NOISE )); then printf '↑%s' "$(pl_human $d)"
  elif (( d <= -PL_TREND_NOISE )); then printf '↓%s' "$(pl_human $(( -d )))"
  else                                  printf 'steady'
  fi
}

# ----------------------------------------------------------------- trends --
# The guard logs free bytes on every run, so a point-in-time check becomes a
# trend for free. This is the view that would have caught the original incident
# months earlier: not "you are at 93%", but "you have been falling for weeks".

# Free-space samples, oldest first, one per line: "<epoch> <bytes>".
pl_free_history() {  # $1 = max samples (default 24)
  local max=${1:-24}
  [[ -r $PL_LOG ]] || return 1
  grep -oE '^[0-9-]+T[0-9:]+[+-][0-9]+ guard [A-Z]+ pct=[0-9]+ free=[0-9]+' $PL_LOG 2>/dev/null \
    | sed -E 's/^([0-9-]+)T([0-9:]+)[+-][0-9]+ .*free=([0-9]+)$/\1 \2 \3/' \
    | while read -r d t b; do
        print -r -- "$(date -j -f '%Y-%m-%d %H:%M:%S' "$d $t" '+%s' 2>/dev/null) $b"
      done | grep -E '^[0-9]+ [0-9]+$' | tail -$max
}

# Unicode block sparkline. Scaled to the observed range rather than to zero —
# the question is "which way is this moving", and a 0-500 GB axis flattens every
# real change into a straight line.
pl_sparkline() {  # reads "<epoch> <bytes>" lines on stdin
  local -a v; local l
  while read -r _ b; do v+=($b); done
  (( ${#v} < 2 )) && return 1
  local min=${v[1]} max=${v[1]} x
  for x in $v; do (( x < min )) && min=$x; (( x > max )) && max=$x; done
  local span=$(( max - min ))
  local -a blocks=('▁' '▂' '▃' '▄' '▅' '▆' '▇' '█')
  local out=""
  for x in $v; do
    if (( span == 0 )); then out+="▄"
    else out+=${blocks[$(( x == max ? 8 : (x - min) * 8 / span + 1 ))]}
    fi
  done
  print -r -- "$out"
}

# How long a stretch of samples actually covers, in words. Each branch carries
# its own preposition: appending a bare window to a fixed "over " produced
# "−4.6 GB over under an hour" for any sample under an hour.
pl_window_phrase() {  # $1 = seconds -> "over 3d" / "over 12h" / "in under an hour"
  local hours=$(( ${1:-0} / 3600 ))
  if   (( hours >= 48 )); then print -rn -- "over $(( hours / 24 ))d"
  elif (( hours >= 1  )); then print -rn -- "over ${hours}h"
  else                         print -rn -- "in under an hour"
  fi
}

# Seconds between the oldest and newest sample on stdin. A window setting says
# how far back to LOOK; this says how much history was actually there, which for
# the first week of any install is a great deal less.
pl_series_span() {  # reads "<epoch> <bytes>" lines on stdin
  local -a e; local ts by
  while read -r ts by; do e+=($ts); done
  (( ${#e} < 2 )) && return 1
  print -r -- $(( e[-1] - e[1] ))
}

# Human delta between the oldest and newest sample, with the window it spans.
pl_free_delta() {  # reads "<epoch> <bytes>" lines on stdin
  local -a e b; local ts by
  while read -r ts by; do e+=($ts); b+=($by); done
  (( ${#b} < 2 )) && return 1
  local d=$(( b[-1] - b[1] ))
  local sign="+"; (( d < 0 )) && { sign="−"; d=$(( -d )) }
  print -r -- "${sign}$(pl_human $d) $(pl_window_phrase $(( e[-1] - e[1] )))"
}

# --------------------------------------------------------------- execution --
# Every destructive helper routes through here. PL_APPLY=0 (the default) prints
# what would happen and touches nothing.
: ${PL_APPLY:=0}

pl_run() {  # pl_run <label> <command…>
  local label=$1; shift
  if (( PL_APPLY )); then
    print -r -- "  ${PL_GRN}RUN${PL_RST}  $label"
    "$@" >/dev/null 2>&1 || print -r -- "       ${PL_YEL}(non-zero exit, continuing)${PL_RST}"
  else
    print -r -- "  ${PL_DIM}DRY${PL_RST}  $label"
  fi
}

pl_rm() {  # pl_rm <label> <path…> — reports reclaimable size, then removes
  local label=$1; shift
  local total=0 p
  for p in "$@"; do (( total += $(pl_size_of $p) )); done
  (( total == 0 )) && return 0
  if (( PL_APPLY )); then
    print -r -- "  ${PL_GRN}RUN${PL_RST}  $label  ($(pl_human $total))"
    rm -rf -- "$@" 2>/dev/null || true
  else
    print -r -- "  ${PL_DIM}DRY${PL_RST}  $label  ($(pl_human $total))"
  fi
  print -r -- $total > /dev/null
}

# ------------------------------------------------ migration from the old name --
# This toolkit was called sparkling-clean through v0.7.1. A machine that had it
# installed carries four artifacts under the old name, and three of them cause
# real trouble if they survive alongside the new ones:
#
#   1. The LaunchAgent. Both guards would run: double notifications, two writers
#      appending to one log, and the de-dup state split across two files so
#      neither suppresses correctly. This is the one that must be handled first.
#   2. The state directory. It holds the health log the sparkline and the
#      "-4.0 GB over 9h" delta are drawn from. Leaving it behind does not break
#      anything, it just silently restarts the trend from empty.
#   3. The SwiftBar plugin symlink, pointing into a Cellar path that brew is
#      about to remove. SwiftBar shows a broken plugin rather than an error.
#   4. SC_* overrides in a shell profile or plist. Nothing can migrate those for
#      the user, so say so rather than silently ignoring them.
#
# Moves, never copies-and-deletes: every step here has to be safe to interrupt,
# and none of it may destroy state if the new name already has some.
PL_LEGACY_LABEL=com.sparklingclean.diskguard
PL_LEGACY_STATE=$HOME/.local/state/sparkling-clean
PL_LEGACY_PLUGIN="$HOME/Library/Application Support/SwiftBarPlugins/sparkling-clean.10m.sh"

pl_migrate_legacy() {
  local plist=$HOME/Library/LaunchAgents/$PL_LEGACY_LABEL.plist

  # 1. Old guard. Unload before the new one loads, or they overlap. `unload` on
  #    a plist launchd never loaded is an error; that case is the normal one
  #    when only the file is left behind, so its status is not interesting.
  if [[ -e $plist ]]; then
    launchctl unload "$plist" 2>/dev/null
    rm -f "$plist"
    print -r -- "migrated: removed the old guard ($PL_LEGACY_LABEL)"
  fi
  # Belt and braces: a label can stay registered after its plist is deleted by
  # hand, which is exactly how someone ends up with two guards and no old file.
  if launchctl list 2>/dev/null | grep -q "$PL_LEGACY_LABEL"; then
    launchctl remove "$PL_LEGACY_LABEL" 2>/dev/null
  fi

  # 2. State. Only when the new location is absent — if both exist the new one
  #    is authoritative and the old one is left alone for the user to inspect.
  if [[ -d $PL_LEGACY_STATE && ! -e $PL_STATE_DIR ]]; then
    mkdir -p "${PL_STATE_DIR:h}"
    if mv "$PL_LEGACY_STATE" "$PL_STATE_DIR" 2>/dev/null; then
      # The log is the only file whose name carried the toolkit's name; the
      # caches and the guard state keep theirs.
      [[ -e $PL_STATE_DIR/sparkling-clean.log && ! -e $PL_LOG ]] &&
        mv "$PL_STATE_DIR/sparkling-clean.log" "$PL_LOG" 2>/dev/null
      print -r -- "migrated: state and health history -> $PL_STATE_DIR"
    fi
  elif [[ -d $PL_LEGACY_STATE && -d $PL_STATE_DIR ]]; then
    print -ru2 -- "note: $PL_LEGACY_STATE still exists; $PL_STATE_DIR is in use. Left both alone."
  fi

  # 3. Menu bar. The symlink points into a Cellar path brew removes on upgrade,
  #    so it is dead either way; repoint it when the new plugin is findable.
  if [[ -L $PL_LEGACY_PLUGIN || -e $PL_LEGACY_PLUGIN ]]; then
    rm -f "$PL_LEGACY_PLUGIN"
    local new="${PL_LEGACY_PLUGIN:h}/plimsoll.10m.sh" cand
    if [[ ! -e $new ]]; then
      for cand in \
        "$(brew --prefix 2>/dev/null)/opt/plimsoll/libexec/extra/swiftbar/plimsoll.10m.sh" \
        "${PL_LIB_DIR:h:h}/extra/swiftbar/plimsoll.10m.sh"
      do
        [[ -r $cand ]] && { ln -sf "$cand" "$new"; break }
      done
    fi
    print -r -- "migrated: SwiftBar plugin -> ${new:t}"
  fi

  # 4. Overrides we cannot move for them.
  local stale=(${(M)${(k)parameters}:#SC_*})
  if (( ${#stale} )); then
    print -ru2 -- "note: ${#stale} SC_* variable(s) still set (${stale[1,3]}). The prefix is now PL_*; the old names are ignored."
  fi

  return 0
}

pl_require_macos() {
  [[ $(uname -s) == Darwin ]] || { print -ru2 -- "plimsoll: macOS only"; exit 1 }
}
