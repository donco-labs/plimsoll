#!/usr/bin/env zsh
# disk-guard.zsh — threshold watchdog. Read-only; notifies, never deletes.
#
#   ./bin/disk-guard.zsh            check once, notify if warranted
#   ./bin/disk-guard.zsh --force    notify regardless of de-dup window
#   ./bin/disk-guard.zsh --quiet    log only, no desktop notification
#
# Exit: 0 healthy · 1 warning · 2 critical   (usable from cron/launchd/CI)
#
# Thresholds via env (see lib/common.zsh): SC_WARN_PCT (15), SC_CRIT_PCT (10).
# Designed for launchd — see launchd/ and `make install-guard`.

emulate -L zsh
setopt no_err_return
source ${0:A:h}/lib/common.zsh
sc_require_macos

local force=0 quiet=0 json=0
while (( $# )); do
  case $1 in
    --force) force=1 ;;
    --quiet) quiet=1 ;;
    --json)  json=1; quiet=1 ;;
    -h|--help) sed -n '2,14p' ${0:A}; exit 0 ;;
  esac
  shift
done

local STATE=$SC_STATE_DIR/guard.state
mkdir -p $SC_STATE_DIR

# The last backup's figures, warmed BEFORE the checks rather than after.
#
# `log show --info` runs about a second, so it is not something to re-pay on
# every render -- but the cache is keyed to the BACKUP, not to a clock, so a
# stale cache means a backup has completed since the last run. That is hourly at
# most. Waiting for it costs a second an hour; the renders in between still pay
# nothing, which is the trade the detached refresh was protecting.
#
# This used to sit below sc_run_health_checks and only launch the refresh, so
# the figures always landed one run late. On an hourly backup against a
# ten-minute menu bar that left the Backup row showing a time with no size for a
# whole render window after every backup -- about one look in six, which reads
# as a missing feature rather than a pending one.
#
# ORDER IS THE POINT: sc_run_health_checks builds the Backup row's headline and
# detail from this cache, so a refresh that finishes after it has run cannot
# reach this pass. Anything warming the cache has to go above this line.
#
# The launch stays fully detached so that giving up on the wait does not kill
# the refresh: it finishes on its own and the figures are there next run.
if sc_tm_last_stats_stale; then
  ( nice -n 15 zsh -c "source ${0:A:h}/lib/common.zsh; sc_tm_last_stats_refresh" >/dev/null 2>&1 & ) &!
  sc_tm_last_stats_wait "$(sc_tm_last_backup_epoch)"
fi

sc_run_health_checks

# Sizing the watchlist costs ~10s of directory walking. The guard runs every two
# hours; the cache is half-day stale at most, so this actually does work about
# twice a day. Detached and niced so it never delays a check or competes with
# anything the user is doing — a disk monitor that generates sustained I/O is
# the problem it exists to find.
if sc_sizes_stale; then
  ( nice -n 15 zsh -c "source ${0:A:h}/lib/common.zsh; sc_sizes_refresh" >/dev/null 2>&1 & ) &!
fi

local level=$(sc_overall_level) rc=0
case $level in (CRIT) rc=2 ;; (WARN) rc=1 ;; esac

# Name the subsystem that is actually unhealthy, not whichever one happens to be
# checked first. "Backup CRIT: 61 days" beats "Disk CRIT: 22% free" on a machine
# with 121 GB spare.
local worst=$(sc_worst_check)
local subject=$(sc_check_name $worst)
local headline=$(sc_check_headline $worst)

# Body: only the checks that are not OK, then history as context.
local -a lines
local c lvl
for c in $SC_CHECKS; do
  lvl=$(sc_check_level $c)
  [[ $lvl == OK ]] && continue
  lines+=("$(sc_check_detail $c)")
done
local msg="${(j: :)lines}"
[[ -z $msg ]] && msg="$(sc_check_detail $worst)"
(( ${#SC_NOTES} )) && msg="$msg  [${(j:; :)SC_NOTES}]"

# ---- log always -------------------------------------------------------------
# free= and pct= are what make a trend possible later; the per-check refactor
# dropped them and the history quietly stopped accumulating.
# An unreadable volume logs "?" rather than an empty field or a zero. The trend
# reader only matches digits, so a measurement that never happened is skipped
# instead of being plotted as a cliff to nothing.
local log_pct=$(sc_pct_free) log_free=$(sc_free_bytes)
sc_log "guard $level pct=${log_pct:-?} free=${log_free:-?} subject=$subject headline=\"$headline\" notes=${(j:,:)SC_NOTES}"

# ---- de-dup: renotify only on escalation, or once per SC_RENOTIFY_H hours ---
# State holds TWO independent facts, and conflating them is a bug: the last level
# SEEN (drives change detection, always updated) and the last time we actually
# NOTIFIED (drives the repeat window, updated only when a notification fires).
# With one field, a --quiet run silently consumes a pending level change and the
# real notification never happens.
: ${SC_RENOTIFY_H:=12}
local prev_level="" prev_notify_ts=0
[[ -r $STATE ]] && IFS=$'\t' read -r prev_level prev_notify_ts < $STATE
local now=$(date +%s)

# A laptop that leaves the house every weekday cannot reach a NAS at home, and
# the Last attempt row correctly goes WARN saying so. Pushing a desktop notification
# about it every morning trains you to dismiss the guard unread, which is how a
# monitor stops working. Suppress the NOTIFICATION, never the row: the report,
# the menu bar and the exit code still say WARN, because backups genuinely are
# not happening.
#
# Only when it is the sole complaint. Away plus a filling disk is news, and
# CRIT never qualifies -- if you stay away long enough the Backup age row
# escalates, and that is the signal this whole suppression relies on existing.
local away_only=0
if [[ $level == WARN ]] && (( SC_TM_AWAY )); then
  local -a bad
  for c in $SC_CHECKS; do
    [[ $(sc_check_level $c) == OK ]] && continue
    bad+=("$(sc_check_name $c)")
  done
  (( ${#bad} == 1 )) && [[ $bad[1] == "Last attempt" ]] && away_only=1
fi

# Change detection keys on this rather than the bare level, so a suppressed
# away-WARN does not consume the transition a real WARN needs. Without it,
# WARN(away) -> WARN(snapshots) reads as "no change" and stays silent for the
# next twelve hours.
local notify_key=$level
(( away_only )) && notify_key=WARN-away

local should_notify=0
if   (( force ));                                                            then should_notify=1
elif [[ $level != OK && $notify_key != $prev_level ]];                       then should_notify=1
elif [[ $level != OK ]] && (( now - prev_notify_ts > SC_RENOTIFY_H * 3600 )); then should_notify=1
fi

# --force still speaks: it means "tell me regardless of the de-dup window", and
# that includes this one.
(( away_only && ! force )) && should_notify=0

# A suppressed notification must not advance the notify clock, so a later
# non-quiet run still delivers it.
local notify_ts=$prev_notify_ts
(( should_notify && ! quiet )) && notify_ts=$now
printf '%s\t%s\n' $notify_key $notify_ts > $STATE

# ---- machine-readable ------------------------------------------------------
# Consumed by the SwiftBar plugin and by CI. Hand-rolled rather than pulling in
# jq: this toolkit has no runtime dependencies and that is worth keeping.
if (( json )); then
  local first=1   # NOT `local c` — c is declared above, and zsh
                  # prints an existing var when typeset gets no assignment
  printf '{"level":"%s","exit":%d,"subject":"%s","headline":"%s","checks":[' \
         $level $rc "$subject" "$headline"
  for c in $SC_CHECKS; do
    (( first )) || printf ','
    first=0
    printf '{"level":"%s","name":"%s","headline":"%s","detail":"%s"}' \
      "$(sc_check_level $c)" "$(sc_check_name $c)" "$(sc_check_headline $c)" \
      "$(sc_check_detail $c | sed 's/"/\\"/g')"
  done
  printf '],"notes":['
  first=1
  for c in $SC_NOTES; do
    (( first )) || printf ','
    first=0
    printf '"%s"' "${c//\"/\\\"}"
  done
  printf ']}\n'
  exit $rc
fi

# ---- output -----------------------------------------------------------------
case $level in
  (CRIT) sc_crit "${subject}: ${headline}" ;;
  (WARN) sc_warn "${subject}: ${headline}" ;;
  (OK)   sc_ok   "all checks pass" ;;
esac
for c in $SC_CHECKS; do
  [[ $(sc_check_level $c) == OK ]] && continue
  sc_info "$(sc_check_detail $c)"
done
for n in $SC_NOTES; do sc_dim "      note: $n"; done

if (( should_notify && ! quiet )); then
  local title="${subject} ${level}: ${headline}"
  if (( $+commands[terminal-notifier] )); then
    terminal-notifier -title "$title" -message "$msg" -group sparkling-clean 2>/dev/null
  else
    # Escape double quotes for the AppleScript string literal.
    osascript -e "display notification \"${msg//\"/\\\"}\" with title \"${title//\"/\\\"}\"" 2>/dev/null
  fi
  [[ $level == CRIT ]] && sc_info "run: $(dirname ${0:A})/reclaim.zsh --tier 2 --apply"
fi

exit $rc
