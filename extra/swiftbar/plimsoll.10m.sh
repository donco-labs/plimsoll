#!/usr/bin/env zsh
# <xbar.title>plimsoll</xbar.title>
# <xbar.version>v1.0</xbar.version>
# <xbar.author>plimsoll</xbar.author>
# <xbar.desc>Disk, swap-headroom and Time Machine health in the menu bar.</xbar.desc>
# <xbar.dependencies>zsh</xbar.dependencies>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
#
# SwiftBar / xbar plugin. Install:
#   brew install --cask swiftbar
#   ln -s "$PWD/extra/swiftbar/plimsoll.10m.sh" ~/Library/Application\ Support/SwiftBar/
#
# Reads disk-guard --json (~0.4s). It deliberately does NOT run the full report,
# which walks 100k-entry trees with find(1) and takes tens of seconds — far too
# slow for something the menu bar re-runs every ten minutes.
#
# Nothing here needs sudo or Full Disk Access: every check behind it is
# read-only and unprivileged by design.

emulate -L zsh
setopt no_err_return

# Row colour rides in the text as an ANSI escape, not in the `color=` parameter,
# because on macOS 26 SwiftBar (2.1.2b3) renders every row as an attributed
# title and wraps a `color=`-styled one in a tracking subclass:
#
#     item.attributedTitle = if params.color != nil, !params.ansi {
#         MenuTrackingAttributedTitle(titleWithImage)
#
# That subclass forces NSColor.selectedMenuItemTextColor over the row while the
# pointer is on it. Un-highlighting flips the flag back and calls itemChanged(),
# which on macOS 26 does not make AppKit re-read the title -- so the row keeps
# the highlight colour until the whole menu is rebuilt. An orange WARN went dark
# on rollover and stayed dark until the menu was closed and reopened.
#
# An ANSI-coloured row is exempt from that wrapper. `color=` stays on every row
# anyway: SwiftBar gives a row a target only when it has an action OR a colour,
# and a row with no target is auto-disabled -- dimmed, and refusing to highlight.
# Verified in SwiftBar on 2026-09-11: ANSI rows survive rollover, param-coloured
# rows do not, and an ANSI row without `color=` renders washed out.
#
# Indices rather than names, because SwiftBar's 256-colour table is its own
# arithmetic: these three resolve to rgb(255,135,0), pure red, and #808080.
local PL_TINT_WARN=$'\e[38;5;208m'
local PL_TINT_CRIT=$'\e[38;5;196m'
local PL_TINT_DIM=$'\e[38;5;244m'

# Resolve the toolkit whether this is symlinked from a checkout or installed by
# Homebrew. SwiftBar runs plugins with a minimal PATH, so brew --prefix is not
# assumed to be on it.
local PL=""
for candidate in \
  "${0:A:h:h:h}/bin/disk-guard.zsh" \
  "/opt/homebrew/opt/plimsoll/libexec/bin/disk-guard.zsh" \
  "/usr/local/opt/plimsoll/libexec/bin/disk-guard.zsh"
do
  [[ -x $candidate || -r $candidate ]] && { PL=$candidate; break }
done

if [[ -z $PL ]]; then
  print -r -- "💾 ?"
  print -r -- "---"
  print -r -- "${PL_TINT_CRIT}plimsoll not found | color=red ansi=true"
  print -r -- "Expected beside this plugin or under brew's opt prefix."
  exit 0
fi

source ${PL:h}/lib/common.zsh 2>/dev/null

local json
json=$(zsh "$PL" --json 2>/dev/null)
local cli=${PL:h}/plimsoll
if [[ -z $json ]]; then
  print -r -- "💾 ?"
  print -r -- "---"
  print -r -- "${PL_TINT_CRIT}guard produced no output | color=red ansi=true"
  exit 0
fi

# Minimal field extraction — no jq, to keep the zero-dependency promise.
# Restricted to the object prefix BEFORE "checks": the key level also appears
# inside every check, and sed's greedy .* would otherwise return the LAST match
# — the level of the last check rather than the roll-up of all of them.
local head=${json%%,\"checks\":*}
jget() { print -r -- "$head" | sed -E "s/.*\"$1\":\"([^\"]*)\".*/\1/" }

local level=$(jget level)

# SF Symbols render as template images: monochrome, and they follow the menu bar
# appearance the way every native item does. An emoji cannot — it is always full
# colour, and 💾 is a save icon from 1998 besides.
#
# The item is a glyph and never text. Menu bar width is shared with every other
# app on the machine, and a status that is only sometimes wide makes the whole
# right-hand side shift when it changes. The one moment it would claim that space
# is also the moment it helps least: the subject alone is a bare noun — the
# CRIT that prompted this read "Attempts", which named a category and no state
# (the check is "Last attempt" now, but a bare subject is still a bare subject).
# The triangle's job is to say "open me". The condition and its detail live in
# the dropdown, one colour-coded row per check with the sentence in a tooltip,
# which is the only place either can be read in full.
# Severity is weight, not a different symbol. The glyph stays a drive so the item
# is recognisable at a glance in a crowded menu bar, and a warning simply fills
# it in. Only a genuine emergency changes the symbol — a caution triangle for
# "21 snapshots accumulated" reads the same as one for "no backup in 61 days",
# and those are not comparable problems.
case $level in
  (CRIT) print -r -- "| sfimage=exclamationmark.triangle.fill" ;;
  (WARN) print -r -- "| sfimage=internaldrive.fill"            ;;
  (*)    print -r -- "| sfimage=internaldrive"                 ;;
esac

print -r -- "---"
print -r -- "${PL_TINT_DIM}plimsoll · disk and backup health | size=11 color=gray ansi=true href=https://github.com/donco-labs/plimsoll"
print -r -- "---"

# SwiftBar sizes the dropdown to its longest row, and a note is a full sentence.
# Wrap rather than truncate: losing the tail of a sentence is worse than using
# two rows for it.
#
# Check details used to come through here too, until they moved into tooltips.
# Notes have no row of their own to hang a tooltip on -- they ARE the row -- so
# this is what they still use.
#
# A literal "|" would be read as the start of SwiftBar's parameter list and
# silently eat the rest of the row, so it is replaced before emitting.
pl_menu_wrapped() {   # $1 = text · $2 = leading indent · $3 = params · $4 = tint
  local text=${1//|/\u2502} line
  print -r -- "$text" | fold -s -w 64 | while IFS= read -r line; do
    [[ -n ${line// } ]] || continue
    # fold -s leaves the break space on the end of each line; EXTENDED_GLOB is
    # not set here, so trim it the plain way rather than with "${line%% ##}".
    while [[ $line == *' ' ]]; do line=${line% }; done
    print -r -- "${2}${4}${line} | ${3}"
  done
}

# One line per check, colour-coded, worst first is not needed — order is stable
# and matches the report.
print -r -- "$json" \
  | grep -oE '\{"level":"[A-Z]+","name":"[^"]+","headline":"[^"]+","detail":"[^"]*"\}' \
  | while read -r row; do
      local l=$(print -r -- "$row" | sed -E 's/.*"level":"([^"]*)".*/\1/')
      local n=$(print -r -- "$row" | sed -E 's/.*"name":"([^"]*)".*/\1/')
      local h=$(print -r -- "$row" | sed -E 's/.*"headline":"([^"]*)".*/\1/')
      local d=$(print -r -- "$row" | sed -E 's/.*"detail":"([^"]*)".*/\1/')
      # The full sentence rides along as a tooltip. It costs no row and no
      # width, and it is the only way an OK row's detail is reachable at all --
      # visible detail rows are printed for problems only, so on a healthy
      # machine every detail string was going into the JSON and reaching no
      # one. Hovering now answers "why is this OK" as well as "why is this not".
      #
      # A literal " would end the quoted parameter early and a literal | would
      # start a second parameter list, so both are neutralised first.
      local tip=${d//\"/}
      tip=${tip//|/\u2502}

      # Built up rather than interpolated per branch, so a row with nothing to
      # add prints no trailing "|" at all. A bare pipe is a parameter list with
      # no parameters in it, which is not something to hand a parser on purpose.
      # Every row gets a colour, including the healthy ones, and that is not
      # only about colour. SwiftBar hands an item a target/action when it has
      # an action OR a colour:
      #
      #     if params.hasAction || params.color != nil { item.target = self ... }
      #
      # A tooltip does not qualify. So an uncoloured row got no target, AppKit
      # auto-disabled it, and it rendered grey and refused to highlight -- the
      # system's universal "this does nothing". That was exactly backwards for
      # the OK rows: since the visible detail lines went away, hovering is the
      # ONLY way to read them, and they were the ones styled as inert.
      #
      # A dim grey keeps them recessive against the orange and red, so the
      # severity hierarchy survives; what changes is that they now highlight
      # under the pointer, which is the affordance that says "there is something
      # here". One mid grey rather than a light,dark pair: the colour is an ANSI
      # index now and those are literal RGB, so #808080 is the value that stays
      # legible against a light menu and a dark one both.
      local params="" icon="✓" tint=""
      case $l in
        (CRIT) icon="✗"; tint=$PL_TINT_CRIT; params="color=red ansi=true"    ;;
        (WARN) icon="△"; tint=$PL_TINT_WARN; params="color=orange ansi=true" ;;
        (*)              tint=$PL_TINT_DIM;  params="color=gray ansi=true"   ;;
      esac
      [[ -n $tip && $tip != "$h" ]] && params="${params:+$params }tooltip=\"${tip}\""
      print -r -- "${tint}${icon} ${n}: ${h}${params:+ | $params}"

      # The explanation lives in the tooltip and nowhere else. Printing it in
      # the open as well put the same sentence on screen twice -- once under
      # the row, once floating beside it -- and cost up to five rows to do it.
      #
      # It is not hiding anything. A condition that needs acting on is PUSHED:
      # the guard's notification body is built from these same detail strings,
      # so a problem announces itself rather than waiting to be hovered. The
      # dropdown is the passive surface, and the one condition deliberately not
      # pushed -- "destination away" -- is also the one whose headline already
      # says the whole thing.
      #
      # The exception is an ACTION, which is not an explanation: the thin offer
      # for snapshots below still gets a row of its own, because a fix nobody
      # can find is not a fix.
    done

# A point-in-time check tells you where you are; the trend tells you where you
# are going, which is the view that would have caught the original incident
# months earlier.
local hist=$(pl_free_history 24 2>/dev/null)
if [[ -n $hist ]]; then
  local spark=$(print -r -- "$hist" | pl_sparkline)
  local delta=$(print -r -- "$hist" | pl_free_delta)
  [[ -n $spark ]] && print -r -- "   ${PL_TINT_DIM}${spark}  ${delta} | font=Menlo size=12 color=gray ansi=true"
fi

# Notes are context, never alarming — dimmed, matching the CHECK/NOTE split.
# Strip the "notes":[ ... ] wrapper FIRST; grepping quoted strings across the
# whole blob also matches the key "notes" itself.
local notes_blob=$(print -r -- "$json" | sed -E 's/.*"notes":\[//; s/\].*//')
if [[ -n $notes_blob ]]; then
  print -r -- "$notes_blob" | tr ',' '\n' | sed -E 's/^"//; s/"$//' \
    | while read -r note; do
        [[ -n $note ]] && pl_menu_wrapped "$note" "" "size=11 color=gray ansi=true" "$PL_TINT_DIM"
      done
fi

print -r -- "---"

# Naming a problem without saying what to do about it is half a monitor. The
# snapshot check is the one people most often cannot act on unaided, so when it
# fires, offer the fix rather than describing it.
if print -r -- "$json" | grep -q '"level":"WARN","name":"Snapshots"'; then
  [[ -x $cli ]] && print -r -- "Thin snapshots to reclaim that space… | bash=${cli} param1=thin terminal=true"
fi

# terminal=true opens Terminal and runs the command there. Two entries, because
# the two reports have very different costs and a menu click should not spring a
# surprise password prompt:
#   --brief  ~1.5s, no sudo   — space, snapshots, Time Machine, exclusions
#   full     ~40s, sudo       — adds SMART, which needs `sudo smartctl`
if [[ -x $cli ]]; then
  print -r -- "Quick summary… | bash=${cli} param1=report param2=--brief terminal=true"
  print -r -- "Full report (~40s, asks for sudo)… | bash=${cli} param1=report terminal=true"
fi
print -r -- "Refresh | refresh=true"

# Where the space actually lives. Read from the cache rather than measured here
# — see pl_sizes_refresh for why a menu bar item must not walk 100k-entry trees
# every ten minutes. Numbers are up to half a day old, which is the right
# resolution for watching creep.
local sizes=$(pl_sizes_read 2>/dev/null)
if [[ -n $sizes ]]; then
  local age=$(pl_sizes_age_hours)
  local when="${age}h ago"; (( age < 1 )) && when="just now"
  print -r -- "---"
  print -r -- "Watchlist · measured ${when}"
  # No cap — this is a submenu and the whole point is seeing the shape of the
  # set. A floor instead, so trivial entries do not pad the list.
  : ${PL_WATCH_FLOOR:=104857600}          # 100 MB
  # Rows carry a colour and a tooltip, which took some care: 0.4.0 gave them a
  #   | bash=/usr/bin/open param1="<path>" terminal=false
  # action and the submenu stopped opening at all, so for two versions these
  # rows were left bare on the theory that submenu rows tolerate no parameters.
  # That theory was wrong -- colour and tooltip parameters are fine, verified in
  # SwiftBar on 2026-09-11 -- and the suspicion still stands where it started:
  # an unquotable space in a bash= param value, not parameters as such.
  #
  # They are not decoration. A row with no colour gets no target from SwiftBar,
  # and a targetless row is disabled: it renders dim AND never highlights, which
  # also means it never shows a tooltip. The tooltip is where a row's trend and
  # its reclaim story live, so the colour is what makes them reachable at all.
  #
  # Grouped by what would actually reclaim the directory rather than listed flat
  # by size. A flat list needed a tag column on every row, and SwiftBar sizes the
  # dropdown to its longest row -- size plus delta plus tag plus a 50-character
  # path is a menu that spans the screen. A heading costs one row per group and
  # none per entry. Sorting is untouched inside each group, so the shape of the
  # set still reads.
  local -A group_rows
  local -a order=(clean-safe clean-more docker-clean yours)
  #
  # Headings name the CLI, not the make target. `make clean-safe` exists only in
  # a clone -- the Homebrew install ships bin/plimsoll and no Makefile,
  # and the targets are one-line wrappers over the CLI anyway. The CLI form is
  # also the safer thing to put in a menu: it is dry-run until you add --apply,
  # where the make targets already carry it. The heading tooltips name the make
  # shortcut for anyone working from a checkout.
  local -A heading=(
    clean-safe    "Tier 1 · plimsoll reclaim"
    clean-more    "Tier 2 · plimsoll reclaim --tier 2"
    docker-clean  "Containers · plimsoll docker"
    yours         "Yours · never reclaimed automatically"
  )
  local -A heading_tip=(
    clean-safe    "Caches that regenerate with no action from you. Dry-run by default: add --apply to actually remove. From a clone: make clean-safe."
    clean-more    "Includes tier 1, plus caches that cost a re-download or a rebuild. Dry-run by default: add --apply. From a clone: make clean-more."
    docker-clean  "Neither reclaim tier touches Docker. plimsoll docker prunes build cache and untagged images, never volumes; --apply --compact to also shrink the disk image. From a clone: make docker-clean."
    yours         "Data, not cache. plimsoll reclaim --tier 3 lists these for you to decide on and never deletes any of them — note that the tiers are cumulative, so adding --apply to that would still clear tiers 1 and 2. From a clone: make review."
  )
  # Every one of these is initialised, because `local name` with no value is
  # `typeset name` at script scope, and zsh PRINTS an existing parameter rather
  # than redeclaring it -- which put "delta=..." and "tip=..." lines into the
  # menu, each one rendering as a row.
  local b="" pth="" tgt="" part="" series="" delta="" spark="" span="" dlabel="" tip="" row=""
  local shown=0
  # A here-string rather than a pipe: a `while read` on the right of a pipe runs
  # in a subshell, and every group built inside it would be discarded at the done.
  while IFS=$'\t' read -r b pth; do
    tgt=$(pl_watch_target "$pth"); part=""
    [[ $tgt == */part ]] && { part=" (part)"; tgt=${tgt%/part} }

    series=$(pl_sizes_series "$pth" 2>/dev/null)
    delta=""; spark=""; span=""
    if [[ -n $series ]]; then
      delta=$(print -r -- "$series" | pl_series_delta) || delta=""
      spark=$(print -r -- "$series" | pl_sparkline)    || spark=""
      # PL_TREND_WINDOW_D is how far back to look, not how much history exists.
      # Saying "in 7d" over two samples 12h apart is a claim about a week that
      # nothing in the file supports -- and for the first week of any install,
      # that is every row.
      span=$(print -r -- "$series" | pl_series_span)   || span=""
    fi
    if [[ -n $delta ]]; then
      dlabel=$(pl_human_delta $delta)
    else
      # Honest rather than reassuring: one measurement is not a trend, and for
      # the first week after this ships that is every row.
      dlabel="new"
    fi

    (( b >= PL_WATCH_FLOOR )) || continue
    (( shown++ ))

    # The tooltip says what the row cannot fit: where it has been, and what
    # would reclaim it. "(part)" in the row is the warning; this is the detail.
    tip="$(pl_human $b) now"
    if [[ -n $delta ]]; then
      # The sparkline is scaled to its own range, so a directory that moved 30 MB
      # draws the same dramatic slope as one that moved 30 GB. Naming the number
      # a steady row actually moved by is what keeps the picture honest.
      local window=$(pl_window_phrase ${span:-0})
      if [[ $dlabel == steady ]]; then
        tip+=" · steady ${window} (±$(pl_human $(( delta < 0 ? -delta : delta ))))"
      else
        tip+=" · ${dlabel} ${window}"
      fi
      [[ -n $spark ]] && tip+=" · ${spark}"
    else
      tip+=" · no trend yet, needs a second measurement"
    fi
    case $tgt in
      (clean-safe)   tip+=" · plimsoll reclaim takes ${part:+named caches inside }this" ;;
      (clean-more)   tip+=" · plimsoll reclaim --tier 2 takes ${part:+part of }this, at the cost of a re-download" ;;
      (docker-clean) tip+=" · neither reclaim tier touches this — plimsoll docker does" ;;
      (*)            tip+=" · data, not cache: nothing here will delete it for you" ;;
    esac

    row=$(printf -- '--%s%10s  %-7s  %s%s' \
      "$PL_TINT_DIM" "$(pl_human $b)" "$dlabel" "${pth/#$HOME/~}" "$part")
    group_rows[$tgt]+="${row} | color=gray ansi=true tooltip=\"${tip//\"/}\""$'\n'
  done <<< "$sizes"

  local g=""
  for g in $order; do
    [[ -n ${group_rows[$g]:-} ]] || continue
    print -r -- "-----"
    print -r -- "--${PL_TINT_DIM}${heading[$g]} | color=gray ansi=true tooltip=\"${heading_tip[$g]//\"/}\""
    print -rn -- "${group_rows[$g]}"
  done

  # The total earns the same trend the rows have -- it is the number that
  # answers "is this machine filling up", and a figure with no direction cannot.
  # Its series comes from the history rather than from summing the rows above,
  # so the directories under the display floor are counted in the movement too.
  local tot=$(print -r -- "$sizes" | awk -F'\t' '{s+=$1} END{print s+0}')
  local cnt=$(print -r -- "$sizes" | grep -c .)
  local totline="$(pl_human $tot) across ${cnt} watched directories"
  local tseries=$(pl_sizes_total_series 2>/dev/null)
  local tdelta="" tspark="" tspan="" ttip="$(pl_human $tot) now"
  if [[ -n $tseries ]]; then
    tdelta=$(print -r -- "$tseries" | pl_series_delta) || tdelta=""
    tspark=$(print -r -- "$tseries" | pl_sparkline)    || tspark=""
    tspan=$(print -r -- "$tseries" | pl_series_span)   || tspan=""
  fi
  if [[ -n $tdelta ]]; then
    local tlabel=$(pl_human_delta $tdelta)
    local twindow=$(pl_window_phrase ${tspan:-0})
    totline+=" · ${tlabel} ${twindow}"
    if [[ $tlabel == steady ]]; then
      ttip+=" · steady ${twindow} (±$(pl_human $(( tdelta < 0 ? -tdelta : tdelta ))))"
    else
      ttip+=" · ${tlabel} ${twindow}"
    fi
    [[ -n $tspark ]] && ttip+=" · ${tspark}"
  else
    ttip+=" · no trend yet, needs a second measurement"
  fi
  (( cnt > shown )) && ttip+=" · counts all ${cnt} watched directories, including $(( cnt - shown )) too small to list"
  print -r -- "-----"
  print -r -- "--${PL_TINT_DIM}${totline} | color=gray ansi=true tooltip=\"${ttip//\"/}\""
  print -r -- "--${PL_TINT_DIM}Caches and images regrow; watch the shape, not the total. | color=gray ansi=true"
fi
print -r -- "---"
print -r -- "About plimsoll"
print -r -- "--${PL_TINT_DIM}Version $(pl_version "$PL") | color=gray ansi=true"
print -r -- "--${PL_TINT_DIM}Warn below ${PL_WARN_PCT}% free · critical below ${PL_CRIT_PCT}% | color=gray ansi=true"
print -r -- "--${PL_TINT_DIM}Backup stale after ${PL_TM_WARN_D}d · critical after ${PL_TM_CRIT_D}d | color=gray ansi=true"
print -r -- "--${PL_TINT_DIM}Failing attempts critical after ${PL_TM_FAIL_CRIT_H}h | color=gray ansi=true"
print -r -- "-----"
print -r -- "--What these checks mean… | href=https://github.com/donco-labs/plimsoll/blob/main/docs/GUIDE.md"
print -r -- "--Repository… | href=https://github.com/donco-labs/plimsoll"
print -r -- "--Report an issue… | href=https://github.com/donco-labs/plimsoll/issues/new"
print -r -- "-----"
print -r -- "--${PL_TINT_DIM}Checks run every 2h in the background | color=gray ansi=true"
print -r -- "--${PL_TINT_DIM}Nothing here changes your Mac without asking | color=gray ansi=true"
