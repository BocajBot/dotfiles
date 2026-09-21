#!/bin/bash
# Claude Code statusline: model+effort | context | 5h/7d rate limits (with reset countdown) | Fable weekly limit (server-side, with reset countdown) | budget-controller mode
input=$(cat)

field() { printf '%s' "$input" | jq -r "$1" 2>/dev/null; }

# GNU/BSD portability: prefer GNU tools when present (macOS: brew coreutils)
DATE=date; command -v gdate >/dev/null 2>&1 && DATE=gdate
TIMEOUT=""; command -v timeout >/dev/null 2>&1 && TIMEOUT="timeout"
[ -z "$TIMEOUT" ] && command -v gtimeout >/dev/null 2>&1 && TIMEOUT="gtimeout"
iso_to_epoch() { # ISO8601 -> epoch: GNU date -d, else python3 (BSD date can't parse ISO)
  "$DATE" -d "$1" +%s 2>/dev/null && return
  python3 -c 'import sys,datetime as d;print(int(d.datetime.fromisoformat(sys.argv[1].replace("Z","+00:00")).timestamp()))' "$1" 2>/dev/null
}

model=$(field '.model.display_name // "?"')
effort=$(field '.effort.level // empty')
ctx_pct=$(field '.context_window.used_percentage // empty')
ctx_used=$(field '.context_window.total_input_tokens // 0')
ctx_size=$(field '.context_window.context_window_size // 200000')
five=$(field '.rate_limits.five_hour.used_percentage // empty')
week=$(field '.rate_limits.seven_day.used_percentage // empty')
five_reset=$(field '.rate_limits.five_hour.resets_at // empty')
week_reset=$(field '.rate_limits.seven_day.resets_at // empty')

fmt_k() { # 123456 -> 123k, 1234567 -> 1.2M
  awk -v n="$1" 'BEGIN{ if (n>=1e6) printf "%.1fM", n/1e6; else if (n>=1e3) printf "%.0fk", n/1e3; else printf "%d", n }'
}

# Fable weekly limit from the OAuth usage endpoint (same source as /usage): server-reported,
# so it covers all devices on the account, and resets_at is the real fixed weekly reset.
# Cache holds "<percent> <resets_at_iso>". The stamp file rate-limits fetch attempts so a
# failing fetch (offline, expired token) retries every 5 min instead of every render, while
# the cache keeps the last good value.
cache="${TMPDIR:-/tmp}/claude_statusline_fable_usage"
stamp="$cache.stamp"
if [ ! -f "$stamp" ] || [ -n "$(find "$stamp" -mmin +5 2>/dev/null)" ]; then
  touch "$stamp"
  (
    tok=$(jq -r '.claudeAiOauth.accessToken // empty' "$HOME/.claude/.credentials.json" 2>/dev/null)
    # macOS stores Claude Code OAuth creds in the Keychain, not a file
    [ -n "$tok" ] || tok=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null |
      jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
    [ -n "$tok" ] || exit 0
    curl -sS -m 5 -H "Authorization: Bearer $tok" -H "anthropic-beta: oauth-2025-04-20" \
         https://api.anthropic.com/api/oauth/usage 2>/dev/null |
      jq -r '[.limits[]? | select(.kind == "weekly_scoped")
              | select((.scope.model.display_name // "") | test("fable"; "i"))][0]
             | select(. != null) | "\(.percent) \(.resets_at)"' > "$cache.tmp" 2>/dev/null
    if [ -s "$cache.tmp" ]; then mv "$cache.tmp" "$cache"; else rm -f "$cache.tmp"; fi
  ) &
fi
fable_pct= fable_reset_iso=
[ -f "$cache" ] && read -r fable_pct fable_reset_iso < "$cache"
fable_reset=""
[ -n "$fable_reset_iso" ] && fable_reset=$(iso_to_epoch "$fable_reset_iso")

# --- budget controller: collector ---------------------------------------------
# Append one observation per constrained window to samples.jsonl (throttled to
# 1/min) and refresh derived state via the engine (pure local math, no network).
BUDGET_DIR="$HOME/.claude/budget"
to_epoch() { case "$1" in ''|*[!0-9]*) iso_to_epoch "$1" || echo 0 ;; *) printf '%s' "$1" ;; esac; }
# Normalize resets to epoch: fmt_eta does integer math, and resets_at may be ISO
[ -n "$five_reset" ] && five_reset=$(to_epoch "$five_reset")
[ -n "$week_reset" ] && week_reset=$(to_epoch "$week_reset")
if [ -d "$BUDGET_DIR" ]; then
  bstamp="$BUDGET_DIR/.sample.stamp"
  # Throttle via epoch stored IN the stamp (find -mmin +0.9 is GNU-only; BSD
  # find rejects fractions, which silently froze sampling on macOS)
  bnow=$(date +%s)
  blast=$(cat "$bstamp" 2>/dev/null); case "$blast" in ''|*[!0-9]*) blast=0;; esac
  if [ $(( bnow - blast )) -ge 55 ]; then
    printf '%s' "$bnow" > "$bstamp"
    {
      [ -n "$five" ] && printf '{"t":%s,"win":"5h","pct":%s,"reset":%s}\n' "$bnow" "$five" "$(to_epoch "$five_reset")"
      [ -n "$week" ] && printf '{"t":%s,"win":"wk","pct":%s,"reset":%s}\n' "$bnow" "$week" "$(to_epoch "$week_reset")"
      [ -n "$fable_pct" ] && printf '{"t":%s,"win":"fablewk","pct":%s,"reset":%s}\n' "$bnow" "$fable_pct" "${fable_reset:-0}"
    } >> "$BUDGET_DIR/samples.jsonl" 2>/dev/null
    # per-session context sample (context tokens are a separate resource)
    bsid=$(field '.session_id // "default"')
    if [ -n "$ctx_used" ] && [ "$ctx_used" != 0 ] && [ "$ctx_used" != null ]; then
      printf '{"t":%s,"used":%s,"size":%s}\n' "$bnow" "$ctx_used" "${ctx_size:-0}" \
        >> "$BUDGET_DIR/ctx/${bsid}.jsonl" 2>/dev/null
    fi
    (${TIMEOUT:+$TIMEOUT 10} python3 "$BUDGET_DIR/engine.py" >/dev/null 2>&1 &)
  fi
fi
# ------------------------------------------------------------------------------

# Round percentages to whole numbers (rate-limit values arrive as floats like 23.5)
round() { [ -n "$1" ] && printf '%.0f' "$1" 2>/dev/null; }
ctx_i=$(round "$ctx_pct"); five_i=$(round "$five"); week_i=$(round "$week"); fable_i=$(round "$fable_pct")

# Per-session delta state: remember this render's values, diff against the last render's
sid=$(field '.session_id // "default"')
state="${TMPDIR:-/tmp}/claude_statusline_delta2_${sid}"
prev_ctx= prev_five= prev_week= prev_fable=
if [ -f "$state" ]; then
  read -r prev_ctx prev_five prev_week prev_fable < "$state"
  [ "$prev_ctx" = - ] && prev_ctx=
  [ "$prev_five" = - ] && prev_five=
  [ "$prev_week" = - ] && prev_week=
  [ "$prev_fable" = - ] && prev_fable=
fi

DIM='\033[2m'; RST='\033[0m'; YEL='\033[33m'; RED='\033[31m'; GRN='\033[32m'; CYA='\033[36m'; ORG='\033[38;5;208m'
pct_color() { # colorize a percentage: NN% tinted green/yellow/red by threshold
  local p=${1%%.*}
  if [ "${p:-0}" -ge 80 ]; then printf "$RED%s%%$RST" "$1"
  elif [ "${p:-0}" -ge 50 ]; then printf "$YEL%s%%$RST" "$1"
  else printf "$GRN%s%%$RST" "$1"; fi
}
effort_color() { # low->green medium->cyan high->yellow xhigh->orange max->red
  case "$1" in
    low)    printf "$GRN%s$RST" "$1" ;;
    medium) printf "$CYA%s$RST" "$1" ;;
    high)   printf "$YEL%s$RST" "$1" ;;
    xhigh)  printf "$ORG%s$RST" "$1" ;;
    max)    printf "$RED%s$RST" "$1" ;;
    *)      printf '%s' "$1" ;;
  esac
}

now=$(date +%s)
fmt_eta() { # epoch seconds -> compact time remaining until reset, e.g. 3d4h / 2h13m / 45m / now
  local target=$1 diff d h m
  [ -z "$target" ] && return
  diff=$(( target - now ))
  if [ "$diff" -le 0 ]; then printf 'now'; return; fi
  d=$(( diff / 86400 )); h=$(( (diff % 86400) / 3600 )); m=$(( (diff % 3600) / 60 ))
  if [ "$d" -gt 0 ]; then printf '%dd%dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh%dm' "$h" "$m"
  else printf '%dm' "$m"; fi
}

# Signed, color-coded change since last render (red = went up/more usage, green = went down).
# Prints nothing when there's no prior value or no change. Leads with a space so it can just append.
delta_pct() { # cur prev  ->  " +3%" / " -12%"
  local cur=$1 prev=$2 d
  { [ -z "$cur" ] || [ -z "$prev" ]; } && return
  d=$(( cur - prev )); [ "$d" -eq 0 ] && return
  if [ "$d" -gt 0 ]; then printf " $RED+%d%%$RST" "$d"
  else printf " $GRN%d%%$RST" "$d"; fi
}

# Pacing display policy: window segments show only unambiguous facts (usage %
# and reset countdown). Every pacing interpretation — on/over pace, projected
# exhaustion, what to do about it — lives in the tail, in words, so there is no
# glyph to misread as a budget or a target. (Removed after ×N, →NN% and
# pace≤NN% were each read as spend-up-to numbers.)

# --- default: ambient telemetry line -------------------------------------------
# Visible spending, invisible scheduling: absolute usage %, reset countdowns,
# context vs the operational window, one state word. Scheduler internals
# (physical %, ac %, trajectory, drivers, GREEN..RED) live in budgetctl and
# the verbose line (`budgetctl verbose on`).
if [ ! -f "$BUDGET_DIR/.verbose" ]; then
  # Terminal-width-aware degradation: measure the assembled line and drop
  # fields by priority (delta -> countdowns -> wk -> state/effort) until it
  # actually fits — no guessed thresholds. Usage percentages survive longest.
  if [ -n "${STATUSLINE_WIDTH:-}" ]; then
    tw=$STATUSLINE_WIDTH
  else
    tw=$(stty size </dev/tty 2>/dev/null | awk '{print $2}')
    [ -n "$tw" ] && [ "$tw" -gt 0 ] 2>/dev/null || tw=${COLUMNS:-0}
  fi
  [ "$tw" -gt 0 ] 2>/dev/null || tw=999
  printf '%s' "$tw" > "$BUDGET_DIR/.lastwidth" 2>/dev/null
  budget=$(( tw - 3 ))   # margin for the host UI's own padding/ellipsis

  acw=$(jq -r '.autoCompactWindow // 0' "$HOME/.claude/settings.json" 2>/dev/null)

  build_line() { # $1 tier: 0 full, 1 -delta, 2 -countdowns(rates kept),
                 # 3 rates->pts (countdowns return), 4 -countdowns, 5 -wk, 6 -state/effort
    local tier=$1 d=1 e=1 r=1 w=1 s=1
    [ "$tier" -ge 1 ] && d=0
    { [ "$tier" -eq 2 ] || [ "$tier" -ge 4 ]; } && e=0
    [ "$tier" -ge 3 ] && r=0
    [ "$tier" -ge 5 ] && w=0
    [ "$tier" -ge 6 ] && s=0
    local o="$model"
    [ "$s" = 1 ] && [ -n "$effort" ] && o+=" $(effort_color "$effort")"
    if [ "${ctx_used:-0}" -gt 0 ] 2>/dev/null; then
      # denominator = the window that governs actual behavior (compact window
      # if known, else physical); one number, one denominator
      local denom=$ctx_size cpct ccol
      [ "${acw:-0}" -gt 0 ] 2>/dev/null && [ "$acw" -le "$ctx_size" ] 2>/dev/null && denom=$acw
      cpct=$(( ctx_used * 100 / denom ))
      if [ "$cpct" -ge 80 ]; then ccol=$RED; elif [ "$cpct" -ge 55 ]; then ccol=$YEL; else ccol=$DIM; fi
      o+=" ${DIM}|${RST} ctx ${ccol}$(fmt_k "$ctx_used")${RST}${DIM}/$(fmt_k "$denom")${RST}"
    fi
    if [ -n "$five" ]; then
      o+=" ${DIM}|${RST} 5h $(pct_color "$five_i")"
      [ "$d" = 1 ] && o+="$(delta_pct "$five_i" "$prev_five")"
      [ "$e" = 1 ] && [ -n "$five_reset" ] && o+=" ${DIM}↻$(fmt_eta "$five_reset")${RST}"
    fi
    if [ "$w" = 1 ] && [ -n "$week" ]; then
      o+=" ${DIM}|${RST} wk $(pct_color "$week_i")"
      [ "$d" = 1 ] && o+="$(delta_pct "$week_i" "$prev_week")"
      [ "$e" = 1 ] && [ -n "$week_reset" ] && o+=" ${DIM}↻$(fmt_eta "$week_reset")${RST}"
    fi
    if [ -n "$fable_i" ]; then
      o+=" ${DIM}|${RST} fable $(pct_color "$fable_i")"
      [ "$d" = 1 ] && o+="$(delta_pct "$fable_i" "$prev_fable")"
      [ "$e" = 1 ] && [ -n "$fable_reset" ] && o+=" ${DIM}↻$(fmt_eta "$fable_reset")${RST}"
    fi
    local bw="$bword"; [ "$r" = 1 ] && bw="${bword_full:-$bword}"   # exhaust gap rides with the rate pairs
    [ "$s" = 1 ] && [ -n "$bw" ] && o+=" ${DIM}|${RST} ${bwcol}${bw}${RST}"
    printf '%s' "$o"
  }
  plain_len() { printf '%b' "$1" | sed 's/\x1b\[[0-9;]*m//g' | wc -m; }
  bstate="$BUDGET_DIR/state.json"
  bword= bwcol= bword_full=
  if [ -f "$bstate" ]; then
    st_t=$(jq -r '.t // 0' "$bstate" 2>/dev/null)
    if [ $(( now - ${st_t:-0} )) -le 1800 ]; then
      IFS=$'\t' read -r jname tj5 tjw tjf p5 l5 v5 pw lw vw pf lf vf pj5 pjw pjf drv dproj dpct dleft dxeta dvel < <(jq -r --arg s "$sid" \
        '[(.ctx_sessions[$s].joint.name // .overall.joint_default // "-"),
          (.windows["5h"].traj_delta_pts // "-"), (.windows["wk"].traj_delta_pts // "-"),
          (.windows["fablewk"].traj_delta_pts // "-"),
          (.windows["5h"].pct // "-"), (.windows["5h"].time_left_s // "-"), (.windows["5h"].velocity_pct_per_h // "-"),
          (.windows["wk"].pct // "-"), (.windows["wk"].time_left_s // "-"), (.windows["wk"].velocity_pct_per_h // "-"),
          (.windows["fablewk"].pct // "-"), (.windows["fablewk"].time_left_s // "-"), (.windows["fablewk"].velocity_pct_per_h // "-"),
          (.windows["5h"].projected_at_reset // "-" | tostring | split(".")[0]),
          (.windows["wk"].projected_at_reset // "-" | tostring | split(".")[0]),
          (.windows["fablewk"].projected_at_reset // "-" | tostring | split(".")[0]),
          (.overall.driver // "-"),
          (.windows[.overall.driver // "-"].projected_at_reset // "-" | tostring | split(".")[0]),
          (.windows[.overall.driver // "-"].pct // "-"),
          (.windows[.overall.driver // "-"].time_left_s // "-"),
          (.windows[.overall.driver // "-"].exhaust_eta_s // "-"),
          (.windows[.overall.driver // "-"].velocity_pct_per_h // "-")
         ] | @tsv' "$bstate" 2>/dev/null)
      # bash 3.2 read drops empty tab fields (shifting everything after a
      # stale window); jq emits "-" placeholders instead — blank them here
      for _v in jname tj5 tjw tjf p5 l5 v5 pw lw vw pf lf vf pj5 pjw pjf drv dproj dpct dleft dxeta dvel; do
        eval "[ \"\$$_v\" = - ] && $_v="
      done
      # tail phrase decodes itself: pacing verdict + the number behind it.
      # Full tail adds the decision numbers: sustainable burn rate that lands
      # exactly at 100% at reset ((100-pct)/hours_left), and how early the
      # window dies at current velocity (time_left - exhaust_eta).
      # Name the scheduler state, not a pace verdict: "allowance lean" is why
      # the budget controller is conserving; the driver's landing explains it in
      # the same →NN% frame as the per-window projections.
      # One verdict in words. Priority: any window projected to exhaust before
      # reset (>=105%) wins the tail and names the action for THAT window —
      # "swap models" only helps fable (its window alone tracks this model);
      # wk counts every model, so its only fix is lighter use. Otherwise the
      # scheduler state, phrased as what the controller is doing (conserving),
      # never as a pace verdict. "on pace" = nothing to do.
      pace_more=
      risk= riskv=104
      [ "${pj5:-0}" -gt "$riskv" ] 2>/dev/null && { risk=5h; riskv=$pj5; }
      [ "${pjw:-0}" -gt "$riskv" ] 2>/dev/null && { risk=wk; riskv=$pjw; }
      [ "${pjf:-0}" -gt "$riskv" ] 2>/dev/null && { risk=fablewk; riskv=$pjf; }
      if [ -n "$risk" ]; then
        case "$risk" in
          fablewk) bword="fable runs out early (→${riskv}%) — swap models" ;;
          wk)      bword="wk runs out early (→${riskv}%) — all models count, go lighter" ;;
          5h)      bword="5h runs out early (→${riskv}%) — resets soon" ;;
        esac
        [ "$riskv" -ge 115 ] 2>/dev/null && bwcol=$RED || bwcol=$YEL
        # idle-to-fix prescription when the engine computed it for this window
        if [ "$risk" = "$drv" ] && [ -n "$dxeta" ] && [ "$dxeta" -lt "${dleft:-0}" ] 2>/dev/null; then
          gap=$(( (dleft - dxeta) / 86400 )); gh=$(( ((dleft - dxeta) % 86400) / 3600 ))
          if [ "$gap" -gt 0 ]; then pace_more=" (or idle ${gap}d${gh}h)"
          else pace_more=" (or idle ${gh}h)"; fi
        fi
      else
        dn=${drv/fablewk/fable}
        case "$jname" in
          NORMAL)          bword="on pace"       bwcol=$GRN ;;
          CONTEXT_LEAN)    bword="ctx tight"     bwcol=$YEL ;;
          ALLOWANCE_LEAN)  bword="conserving${dn:+ ($dn ends ${dproj}%)}"            bwcol=$YEL ;;
          CONSERVE_BOTH)   bword="conserving${dn:+ ($dn ends ${dproj}%)}, ctx tight" bwcol=$ORG ;;
        esac
      fi
      bword_full="$bword$pace_more"
    fi
  fi

  out=$(build_line 0)
  for tier in 1 2 3 4 5 6; do
    [ "$(plain_len "$out")" -le "$budget" ] && break
    out=$(build_line "$tier")
  done
  printf '%s %s %s %s\n' "${ctx_i:--}" "${five_i:--}" "${week_i:--}" "${fable_i:--}" > "$state" 2>/dev/null
  printf '%b\n' "$out"
  exit 0
fi
# --- verbose: full diagnostic line (budgetctl verbose on) ----------------------

out="$model"
[ -n "$effort" ] && out+=" $(effort_color "$effort")"
if [ -n "$ctx_pct" ]; then
  out+=" ${DIM}|${RST} ctx $(pct_color "$ctx_i")$(delta_pct "$ctx_i" "$prev_ctx") ${DIM}($(fmt_k "$ctx_used")/$(fmt_k "$ctx_size"))${RST}"
  # operational compact pressure: utilization of the auto-compact window, which
  # differs from the physical-context percentage above on long-context models
  acw=$(jq -r '.autoCompactWindow // 0' "$HOME/.claude/settings.json" 2>/dev/null)
  if [ "${acw:-0}" -gt 0 ] 2>/dev/null && [ "${ctx_used:-0}" -gt 0 ] 2>/dev/null; then
    ac_i=$(( ctx_used * 100 / acw ))
    out+=" ${DIM}ac${RST} $(pct_color "$ac_i")"
  else
    # compact threshold unknown: say so — never fabricate operational pressure
    out+=" ${DIM}ac ?${RST}"
  fi
fi
if [ -n "$five" ]; then
  out+=" ${DIM}|${RST} 5h $(pct_color "$five_i")$(delta_pct "$five_i" "$prev_five")"
  [ -n "$five_reset" ] && out+=" ${DIM}(↻$(fmt_eta "$five_reset"))${RST}"
fi
if [ -n "$week" ]; then
  out+=" ${DIM}|${RST} wk $(pct_color "$week_i")$(delta_pct "$week_i" "$prev_week")"
  [ -n "$week_reset" ] && out+=" ${DIM}(↻$(fmt_eta "$week_reset"))${RST}"
fi
if [ -n "$fable_i" ]; then
  out+=" ${DIM}|${RST} fablewk $(pct_color "$fable_i")$(delta_pct "$fable_i" "$prev_fable")"
  [ -n "$fable_reset" ] && out+=" ${DIM}(↻$(fmt_eta "$fable_reset"))${RST}"
fi

# --- budget controller: compact mode display ----------------------------------
bstate="$BUDGET_DIR/state.json"
if [ -f "$bstate" ]; then
  bline=$(jq -r '(.overall.mode // "UNKNOWN") + "\t" + (.overall.compact // "?")' "$bstate" 2>/dev/null)
  bmode=${bline%%$'\t'*}; bcompact=${bline#*$'\t'}
  case "$bmode" in
    GREEN)  bcol=$GRN ;;
    BLUE)   bcol=$CYA ;;
    YELLOW) bcol=$YEL ;;
    ORANGE) bcol=$ORG ;;
    RED)    bcol=$RED ;;
    *)      bcol=$DIM ;;
  esac
  [ -n "$bcompact" ] && out+=" ${DIM}|${RST} bdg ${bcol}${bcompact}${RST}"
fi
# ------------------------------------------------------------------------------

# Persist current values for the next render's delta ("-" placeholder keeps columns aligned)
printf '%s %s %s %s\n' "${ctx_i:--}" "${five_i:--}" "${week_i:--}" "${fable_i:--}" > "$state" 2>/dev/null

printf '%b\n' "$out"
