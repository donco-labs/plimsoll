#!/usr/bin/env zsh
# disk-report.zsh — read-only health + space diagnostic. Changes nothing.
#
#   ./bin/disk-report.zsh          full report
#   ./bin/disk-report.zsh --brief  headline numbers only

emulate -L zsh
setopt no_err_return
source ${0:A:h}/lib/common.zsh
pl_require_macos

local brief=0
[[ ${1:-} == (--brief|-b) ]] && brief=1

# ============================================================ 1. THE NUMBER ==
pl_hdr "Disk"
local free total pct=""
if free=$(pl_free_bytes) && total=$(pl_total_bytes); then
  pct=$(pl_pct_free)
  print -r -- "      container   $(pl_human $total)"
  print -r -- "      used        $(pl_human $(( total - free )))"
  print -r -- "      free        $(pl_human $free)   (${pct}%)"
else
  # Saying nothing was measured beats printing 0 B used of 0 B, which is what
  # subtracting two empty strings produced.
  print -r -- "      container   unknown — diskutil could not report ${PL_DATA_VOLUME}"
fi

# pct is tested for emptiness BEFORE it is compared. Under no_unset an arithmetic
# test on an unset parameter does not evaluate false, it errors — and a failed
# (( )) sends the whole if-chain to its else branch, so an unreadable volume
# printed "healthy headroom" with the error hidden on stderr.
if   [[ -z $pct ]];            then pl_warn "free space unreadable — nothing was measured, so no threshold was crossed"
elif (( pct < PL_CRIT_PCT )); then pl_crit "below ${PL_CRIT_PCT}% free — swap cannot grow, jetsam kills likely"
elif (( pct < PL_WARN_PCT )); then pl_warn "below ${PL_WARN_PCT}% free — reclaim soon"
else                               pl_ok   "healthy headroom"
fi

pl_dim "      (df lies here: APFS rows share one container, df uses GiB not GB,"
pl_dim "       and Finder counts purgeable space that df does not.)"

# ========================================================== 2. SNAPSHOTS ====
pl_hdr "Local snapshots"
local snaps=$(pl_snapshot_count)
if (( snaps == 0 )); then
  pl_ok "none — deleted files return space immediately"
else
  pl_warn "$snaps local snapshot(s) holding space from deleted files:"
  pl_snapshot_list | sed 's/^/        /'
  pl_info "reclaim.zsh thins these automatically; or: plimsoll thin (keeps the newest)"
fi

# ====================================================== 3. TIME MACHINE =====
# Warm the last backup's figures before printing anything that reads them. The
# guard normally has them cached already; this covers the report being the first
# thing run after a backup completes, which is otherwise the one case where the
# most detailed surface has the least to say. Same ordering rule as the guard --
# a refresh launched after the lines are built cannot reach them.
#
# The wait is affordable here for a different reason than in the guard: this
# report walks 100k-entry trees and takes tens of seconds, so a second spent
# once per backup does not register.
if pl_tm_last_stats_stale; then
  ( nice -n 15 zsh -c "source ${0:A:h}/lib/common.zsh; pl_tm_last_stats_refresh" >/dev/null 2>&1 & ) &!
  pl_tm_last_stats_wait "$(pl_tm_last_backup_epoch)"
fi

pl_hdr "Time Machine"
if pl_tm_enabled; then
  pl_ok "automatic backups ON"
else
  pl_crit "automatic backups OFF — you are not being backed up"
  pl_info "re-enable: sudo tmutil enable"
fi

# Enabled != working. Age of the last COMPLETED backup is the real signal.
local tm_days
if tm_days=$(pl_tm_days_since_backup); then
  local when=$(pl_tm_last_backup_human)
  if   (( tm_days >= PL_TM_CRIT_D )); then
    pl_crit "last completed backup $when — ${tm_days} days ago"
    pl_info "a chain can fail silently for months; check Time Machine settings"
  elif (( tm_days >= PL_TM_WARN_D )); then
    pl_warn "last completed backup $when — ${tm_days} days ago"
  else
    pl_ok "last completed backup $when (${tm_days}d ago)"
  fi
else
  pl_warn "last completed backup: UNKNOWN (could not read TM preferences)"
fi

# What that backup actually moved. Added against total is the full-vs-incremental
# answer, and the menu bar has carried it in its headline for a while; the report
# had nothing, which put the detail on the glanceable surface and not on the
# thorough one.
#
# Unconditional rather than tucked into the healthy branch above: it prints
# nothing when the figures are unavailable, and that is already every backup old
# enough to have tripped the WARN -- the info-level log holds roughly
# PL_TM_LOG_MAX_H hours and the WARN threshold is counted in days.
local tm_wrote
tm_wrote=$(pl_tm_last_sentence) && pl_info "$tm_wrote"

if pl_tm_running; then
  local prog=$(pl_tm_progress_pct)
  pl_info "backup RUNNING now$( [[ -n $prog ]] && print -n " (${prog}%)" )"
fi

# ================================================ TM EXCLUSION HYGIENE ======
pl_hdr "Time Machine exclusions"
local -a unexcluded unex_rows
local unex_total=0 unex_files=0 cand sz fc
for cand in $PL_TM_EXCLUDE_CANDIDATES; do
  [[ -e $cand ]] || continue
  pl_tm_excluded $cand && continue
  sz=$(pl_size_of $cand); fc=$(pl_file_count $cand)
  pl_tm_worth_excluding $cand $sz $fc || continue
  unexcluded+=("$cand")
  # Rows are built here so size and file count are computed exactly once per
  # path -- find(1) over ~100k-entry trees is the expensive part of this report.
  unex_rows+=("${fc}"$'\t'"$(pl_human $sz)"$'\t'"${fc}"$'\t'"${cand/#$HOME/~}")
  (( unex_total += sz )); (( unex_files += fc ))
done

if (( ${#unexcluded} == 0 )); then
  pl_ok "no large or file-dense rebuildable directories are being backed up"
else
  pl_warn "$(pl_human $unex_total) / ${unex_files} files of rebuildable data in every backup:"
  # Sorted by FILE COUNT: on a network destination that is the real cost, both
  # when copying and again when the backup is later thinned file-by-file.
  print -rl -- $unex_rows | sort -rn -k1 \
    | awk -F'\t' '{printf "        %10s  %9s files  %s\n", $2, $3, $4}'
  pl_info "All are reconstructible from a registry, lockfile or re-download."
  pl_info "Review, then exclude (-p survives the folder being recreated):"
  local cmdline=""
  for cand in $unexcluded; do cmdline+=" ${(q)cand}" ; done
  print -r -- ""
  print -r -- "        sudo tmutil addexclusion -p${cmdline}"
  print -r -- ""
  pl_dim "        Verify:  tmutil isexcluded <path>"
  pl_dim "        Undo:    sudo tmutil removeexclusion -p <path>"
fi

(( brief )) && exit 0

# ========================================================== 4. MEMORY =======
pl_hdr "Memory pressure"
local ram_gb=$(( $(sysctl -n hw.memsize) / 1073741824 ))
print -r -- "      installed   ${ram_gb} GB"
top -l 1 -n 0 2>/dev/null | grep -E '^(PhysMem|VM:)' | sed 's/^/      /'
local swap=$(sysctl -n vm.swapusage 2>/dev/null)
print -r -- "      swap        ${swap}"
pl_dim "      Swap at 0 is fine on its own. Swap at 0 *while* the disk is full is"
pl_dim "      the failure mode: macOS cannot grow a swapfile, so tight RAM goes"
pl_dim "      straight to jetsam kills and pagein thrash."

# =================================================== 5. PRESSURE EVENTS =====
pl_hdr "Recent pressure events (last 14 days)"
local hits=$(pl_pressure_files 14 | grep -c . | tr -d ' ')
if (( hits == 0 )); then
  pl_ok "no jetsam / panic / watchdog / excessive-disk-write reports"
else
  pl_warn "$hits report(s):"
  # Same source as the count above, so the tally and the list cannot disagree.
  pl_pressure_files 14 | head -8 | while read -r f; do
    printf '        %s  %s\n' "$(stat -f '%SB' -t '%b %e %H:%M' "$f")" "${f:t}"
  done
fi

# ============================================================== 6. SMART ====
pl_hdr "SSD health"
if (( $+commands[smartctl] )); then
  { sudo smartctl -a /dev/disk0 2>/dev/null || true; } | grep -E \
    'Critical Warning|Available Spare|Percentage Used|Media and Data|Error Information Log Entries|Temperature:|Data Units' \
    | sed 's/^/      /'
  pl_dim "      Ignore any \"Read N entries from Error Information Log failed …"
  pl_dim "       GetLogPage failed … code=745\" line. Apple Silicon exposes only"
  pl_dim "       NVMe log page 0x02; smartctl asks for 0x01 anyway. Tool artifact."
else
  pl_info "smartctl not installed (brew install smartmontools)"
fi

# ======================================================== 7. BIG OFFENDERS ==
pl_hdr "Largest reclaim candidates"
local -a paths labels
paths=(
  ~/Library/Containers/com.docker.docker
  ~/Library/Application\ Support/com.apple.container
  ~/Library/Developer/Xcode/iOS\ DeviceSupport
  ~/Library/Developer/Xcode/DerivedData
  ~/Library/Caches/Homebrew
  ~/Library/Caches/JetBrains
  ~/Library/Caches/ms-playwright
  ~/Library/Caches/go-build
  ~/.gradle/caches
  ~/.ollama
  ~/.cache
  ~/Downloads
)
{
  for p in $paths; do
    local sz=$(pl_size_of $p)
    (( sz > 500000000 )) && printf '%d\t%s\t%s\n' $sz "$(pl_human $sz)" "${p/#$HOME/~}"
  done
} | sort -rn -k1 | awk -F'\t' '{printf "      %10s  %s\n", $2, $3}'

# ============================================================== 8. DOCKER ===
pl_hdr "Docker"
local raw=~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw
if [[ -e $raw ]]; then
  print -r -- "      Docker.raw allocated  $(pl_size_h $raw)"
  pl_dim "      (ls -lh shows the sparse ceiling — often 460G — not real usage.)"
  if docker info >/dev/null 2>&1; then
    pl_ok "daemon responding"
    docker system df 2>/dev/null | sed 's/^/      /'
  else
    pl_info "daemon not running — start Docker Desktop to inspect/prune"
  fi
else
  pl_info "no Docker disk image"
fi

pl_hdr "Spotlight"
ps -Ao rss,comm 2>/dev/null | grep -Ei 'spotlight|corespotlight|mds_stores' | grep -v grep \
  | awk '{s+=$1} END {printf "      indexing footprint  %d MB\n", s/1024}'
for m in ~/Library/CloudStorage/*(N/); do
  local n=$(mdfind -onlyin "$m" -count "kMDItemFSName == '*'" 2>/dev/null)
  if [[ $n == 0 ]]; then pl_ok "excluded: ${m:t}"
  else pl_warn "INDEXED: ${m:t} ($n items) — consider Spotlight Privacy exclusion"
  fi
done

print

# =============================================================== VERDICT =====
# Same pl_run_health_checks the guard uses, so the report and the notification
# can never disagree about whether this machine is healthy.
pl_hdr "Verdict"
pl_run_health_checks
local c lvl name headline
for c in $PL_CHECKS; do
  lvl=$(pl_check_level $c)
  name=$(pl_check_name $c)
  headline=$(pl_check_headline $c)
  case $lvl in
    (CRIT) printf '  %s  %-13s %s\n' "${PL_RED}CRIT${PL_RST}" "$name" "$headline" ;;
    (WARN) printf '  %s  %-13s %s\n' "${PL_YEL}WARN${PL_RST}" "$name" "$headline" ;;
    (*)    printf '  %s    %-13s %s\n' "${PL_GRN}OK${PL_RST}" "$name" "$headline" ;;
  esac
done
for n in $PL_NOTES; do pl_dim "  note  $n"; done
print
case $(pl_overall_level) in
  (CRIT) pl_crit "action needed" ;;
  (WARN) pl_warn "attention soon" ;;
  (*)    pl_ok   "healthy" ;;
esac
print
