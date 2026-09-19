#!/usr/bin/env zsh
# reclaim.zsh — tiered disk reclamation. DRY-RUN BY DEFAULT.
#
#   ./bin/reclaim.zsh                  show what tier 1 would free (nothing removed)
#   ./bin/reclaim.zsh --apply          actually reclaim tier 1
#   ./bin/reclaim.zsh --tier 2 --apply tier 1 + 2
#   ./bin/reclaim.zsh --tier 3         REPORT ONLY — tier 3 is never automated
#
# Tiers
#   1  caches that regenerate with no user action. No judgment required.
#   2  caches that cost a re-download or a rebuild. Safe, but you will notice.
#   3  data. NEVER deleted by this script — reported so you can decide.

emulate -L zsh
setopt no_err_return
source ${0:A:h}/lib/common.zsh
pl_require_macos

local tier=1
while (( $# )); do
  case $1 in
    --apply)      PL_APPLY=1 ;;
    --tier|-t)    shift; tier=$1 ;;
    --no-thin)    PL_NO_THIN=1 ;;
    -h|--help)    sed -n '2,20p' ${0:A}; exit 0 ;;
    *) print -ru2 -- "unknown flag: $1"; exit 2 ;;
  esac
  shift
done

local before=$(pl_free_bytes)
print -r -- "${PL_BLD}plimsoll reclaim${PL_RST}  tier=$tier  mode=$( (( PL_APPLY )) && print APPLY || print DRY-RUN )"
print -r -- "free before: $(pl_free_h)  ($(pl_pct_free_h))"

# Refuse to start on top of a running backup. pl_tm_pause runs `tmutil disable`,
# which does not wait politely — it stops the backup in progress. On a machine
# whose chain is already struggling, silently killing the run you have been
# waiting on is a far worse outcome than reclaiming ten minutes later.
if (( PL_APPLY )) && pl_tm_running && [[ -z ${PL_ALLOW_DURING_BACKUP:-} ]]; then
  pl_crit "a backup is running — refusing to reclaim"
  pl_info "This pauses Time Machine before it starts, which aborts the backup in"
  pl_info "progress. Your existing backups are not at risk; the run in flight is."
  pl_info "Wait for it to finish, or set PL_ALLOW_DURING_BACKUP=1 to override."
  exit 2
fi

# Pause TM so a fresh snapshot cannot re-pin what we delete. Trap restores it.
(( PL_APPLY )) && pl_tm_pause

# =================================================================== TIER 1 ==
pl_hdr "Tier 1 — regenerating caches (no user action to restore)"

# Xcode. DeviceSupport is usually the single biggest safe win; it is re-created
# automatically the next time you attach that iOS device.
pl_rm "Xcode iOS DeviceSupport"  ~/Library/Developer/Xcode/iOS\ DeviceSupport/*(N)
pl_rm "Xcode DerivedData"        ~/Library/Developer/Xcode/DerivedData/*(N)
pl_rm "Xcode Archives (>90d)"    ~/Library/Developer/Xcode/Archives/*(Nm+90)

# Homebrew keeps every downloaded bottle plus its own vendored ruby per upgrade.
if (( $+commands[brew] )); then
  local bsz=$(pl_size_of $(brew --cache 2>/dev/null))
  pl_run "brew cleanup -s --prune=all  ($(pl_human $bsz))" brew cleanup -s --prune=all
fi

# Language/toolchain build caches — all rebuild on next compile.
pl_rm "Go build cache"           ~/Library/Caches/go-build(N)
pl_rm "JetBrains caches"         ~/Library/Caches/JetBrains(N)
pl_rm "rattler (conda) cache"    ~/Library/Caches/rattler(N)
pl_rm "node-gyp cache"           ~/Library/Caches/node-gyp(N)
pl_rm "CocoaPods cache"          ~/Library/Caches/CocoaPods(N)
pl_rm "pip cache"                ~/Library/Caches/pip(N)
pl_rm "Yarn cache"               ~/Library/Caches/Yarn(N)
pl_rm "Spotify cache"            ~/Library/Caches/com.spotify.client(N)

(( $+commands[pnpm] )) && pl_run "pnpm store prune"      pnpm store prune
(( $+commands[npm]  )) && pl_run "npm cache clean"       npm cache clean --force
(( $+commands[uv]   )) && pl_run "uv cache prune"        uv cache prune

# =================================================================== TIER 2 ==
if (( tier >= 2 )); then
  pl_hdr "Tier 2 — costs a re-download or rebuild"
  pl_rm "Gradle caches"            ~/.gradle/caches(N)
  pl_rm "Playwright browsers"      ~/Library/Caches/ms-playwright(N) ~/Library/Caches/ms-playwright-go(N)
  pl_rm "Android build cache"      ~/.android/cache(N)
  (( $+commands[xcrun] )) && pl_run "delete unavailable simulators" xcrun simctl delete unavailable
  pl_info "Docker is handled separately: ./bin/docker-reclaim.zsh"
fi

# =================================================================== TIER 3 ==
if (( tier >= 3 )); then
  pl_hdr "Tier 3 — DATA. Reported only, never auto-deleted."
  local -a review
  review=(
    ~/.ollama ~/models
    ~/Library/Containers/com.inferencer
    ~/Library/Application\ Support/com.apple.container
    ~/Downloads ~/.cache ~/.npm ~/.pub-cache ~/.konan ~/.rustup ~/.sdkman ~/fvm
  )
  {
    for p in $review; do
      local sz=$(pl_size_of $p)
      (( sz > 200000000 )) && printf '%d\t%s\t%s\n' $sz "$(pl_human $sz)" "${p/#$HOME/~}"
    done
  } | sort -rn -k1 | awk -F'\t' '{printf "      %10s  %s\n", $2, $3}'
  pl_info "Decide these by hand. Local LLM models and Downloads are not cache."
fi

# ================================================================ SNAPSHOTS ==
# THE STEP EVERYONE FORGETS. Files deleted above are still referenced by any
# local Time Machine snapshot taken before now — until thinned, free space
# does not move and it looks like the cleanup did nothing.
if (( PL_APPLY )) && [[ -z ${PL_NO_THIN:-} ]]; then
  pl_hdr "Releasing snapshot-pinned blocks"
  pl_thin_snapshots
fi

pl_tm_restore

# =================================================================== RESULT ==
local after=$(pl_free_bytes)
pl_hdr "Result"
if (( PL_APPLY )); then
  # "reclaimed 0 B" is what subtracting two unreadable measurements looked like,
  # which reads as "this did nothing" rather than "this cannot say".
  if [[ -n $before && -n $after ]]; then
    print -r -- "      before   $(pl_human $before)"
    print -r -- "      after    $(pl_human $after)"
    print -r -- "      ${PL_BLD}reclaimed $(pl_human $(( after - before )))${PL_RST}   now $(pl_pct_free_h) free"
    pl_log "reclaim tier=$tier freed=$(( after - before )) free_pct=$(pl_pct_free)"
  else
    print -r -- "      ${PL_BLD}reclaimed unknown${PL_RST} — free space could not be measured before/after"
    pl_log "reclaim tier=$tier freed=unknown free_pct=unknown"
  fi
else
  print -r -- "      dry run — nothing removed. Re-run with ${PL_BLD}--apply${PL_RST}."
fi
print
