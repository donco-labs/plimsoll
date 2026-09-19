#!/usr/bin/env zsh
# tm-exclude.zsh — apply the codified Time Machine exclusion list. DRY-RUN BY DEFAULT.
#
#   ./bin/tm-exclude.zsh            show what would change
#   ./bin/tm-exclude.zsh --apply    exclude every candidate that exists
#   ./bin/tm-exclude.zsh --status   applied / not-applied table
#   ./bin/tm-exclude.zsh --undo     remove exclusions this list added
#
# The candidate list lives in lib/common.zsh (PL_TM_EXCLUDE_CANDIDATES) and is
# versioned, so a rebuilt machine gets the same policy with one command.
#
# NOTE: tmutil addexclusion needs Full Disk Access. Run this from a terminal that
# has it (System Settings → Privacy & Security → Full Disk Access).
#
# Why this applies to EVERY existing candidate, not just the ones disk-report
# flags: the report's size/count thresholds exist to surface offenders worth your
# attention. They are the wrong basis for policy. A freshly-emptied DerivedData is
# under threshold today and back to gigabytes next week — on this machine exactly
# that happened, and the two Xcode directories silently stayed in every backup.

emulate -L zsh
setopt no_err_return
source ${0:A:h}/lib/common.zsh
pl_require_macos

local mode=dry
while (( $# )); do
  case $1 in
    --apply)   mode=apply ;;
    --status)  mode=status ;;
    --undo)    mode=undo ;;
    -h|--help) sed -n '2,20p' ${0:A}; exit 0 ;;
    *) print -ru2 -- "unknown flag: $1"; exit 2 ;;
  esac
  shift
done

local -a present missing already
local c
for c in $PL_TM_EXCLUDE_CANDIDATES; do
  if [[ ! -e $c ]];        then missing+=("$c")
  elif pl_tm_excluded $c;  then already+=("$c")
  else                          present+=("$c")
  fi
done

if [[ $mode == status ]]; then
  pl_hdr "Time Machine exclusion policy"
  for c in $already; do pl_ok   "${c/#$HOME/~}" ; done
  for c in $present; do pl_warn "${c/#$HOME/~}  — exists, NOT excluded" ; done
  for c in $missing; do pl_dim  "      absent   ${c/#$HOME/~}" ; done
  print
  print -r -- "      ${#already} applied · ${#present} pending · ${#missing} absent (of ${#PL_TM_EXCLUDE_CANDIDATES})"
  print
  exit $(( ${#present} > 0 ))
fi

if [[ $mode == undo ]]; then
  pl_hdr "Removing exclusions"
  (( ${#already} == 0 )) && { pl_ok "nothing to remove"; exit 0 }
  for c in $already; do print -r -- "        ${c/#$HOME/~}"; done
  print -r -- ""
  print -r -- "        sudo tmutil removeexclusion -p${(j: :)${(q)already/#/ }}"
  print
  pl_info "Review, then run the line above. This script does not remove exclusions for you."
  exit 0
fi

pl_hdr "Time Machine exclusions"
pl_info "${#already} already applied · ${#missing} absent (will be caught on a later run)"

if (( ${#present} == 0 )); then
  pl_ok "every existing candidate is already excluded"
  exit 0
fi

print -r -- ""
local total=0 fc n=0
for c in $present; do
  n=$(pl_file_count $c); (( total += $(pl_size_of $c) ))
  printf '  %10s  %9s files  %s\n' "$(pl_size_h $c)" "$n" "${c/#$HOME/~}"
done
print -r -- ""

local cmdline=""
for c in $present; do cmdline+=" ${(q)c}" ; done

if [[ $mode == apply ]]; then
  pl_info "applying ${#present} exclusion(s) — sudo will prompt…"
  if sudo tmutil addexclusion -p ${present}; then
    print
    local failed=0
    for c in $present; do pl_tm_excluded $c || { pl_crit "FAILED: ${c/#$HOME/~}"; (( failed++ )) } ; done
    (( failed == 0 )) && pl_ok "all ${#present} applied and verified"
    pl_log "tm-exclude applied=${#present} failed=${failed}"
    exit $(( failed > 0 ))
  else
    pl_crit "tmutil failed — does this terminal have Full Disk Access?"
    exit 1
  fi
fi

pl_warn "$(pl_human $total) across ${#present} path(s) would be excluded. Dry run — nothing changed."
pl_info "Apply with:  ${0:t} --apply"
pl_info "Or by hand:"
print -r -- ""
print -r -- "        sudo tmutil addexclusion -p${cmdline}"
print
