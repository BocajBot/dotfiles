#!/usr/bin/env bash
# which-key style command finder for tmux.
#
# Reads every `bind -n` line out of ~/.tmux.conf, so the list is never stale --
# add or change a binding there (alt+shift+e) and it shows up here immediately.
#
# Labels come from a trailing  #= Some label  comment on the bind line.
# Without one, the raw tmux command is shown instead.
#
#   type          filter, e.g. "alt+shift" narrows to the shift bindings
#   enter         run the highlighted binding
#   <the combo>   pressing the real key combo runs it directly
#   esc           close
set -uo pipefail

CONF="${TMUX_CONF:-$HOME/.tmux.conf}"
[[ -r $CONF ]] || { echo "no config at $CONF" >&2; exit 1; }

# tmux key name -> pretty label, and -> fzf --bind name
pretty() {
  local k=$1
  k=${k#M-}
  case $k in
    S-*) printf 'alt+shift+%s' "$(tr 'A-Z' 'a-z' <<<"${k#S-}")" ;;
    [A-Z]) printf 'alt+shift+%s' "$(tr 'A-Z' 'a-z' <<<"$k")" ;;
    PPage) printf 'alt+pageup' ;;
    NPage) printf 'alt+pagedown' ;;
    *) printf 'alt+%s' "$(tr 'A-Z' 'a-z' <<<"$k")" ;;
  esac
}

fzfkey() {
  local k=$1
  k=${k#M-}
  case $k in
    S-Up|S-Down|S-Left|S-Right) printf 'alt-shift-%s' "$(tr 'A-Z' 'a-z' <<<"${k#S-}")" ;;
    Up|Down|Left|Right)         printf 'alt-%s' "$(tr 'A-Z' 'a-z' <<<"$k")" ;;
    PPage)                      printf 'alt-pgup' ;;
    NPage)                      printf 'alt-pgdn' ;;
    Space)                      printf 'alt-space' ;;
    [A-Za-z0-9])                printf 'alt-%s' "$k" ;;
    *)                          printf '' ;;   # punctuation: filter-only
  esac
}

rows=()      # display rows, TAB separated: key <TAB> label <TAB> command
binds=()     # fzf --bind arguments

while IFS= read -r line; do
  # a bind may be split over several lines with a trailing backslash -- join them
  while [[ $line == *\\ ]]; do
    line=${line%\\}
    IFS= read -r cont || break
    cont=${cont#"${cont%%[![:space:]]*}"}
    line+=" $cont"
  done
  [[ $line =~ ^[[:space:]]*bind[[:space:]]+-n[[:space:]]+ ]] || continue
  rest=${line#*-n }
  rest=${rest#"${rest%%[![:space:]]*}"}
  key=${rest%% *}
  cmd=${rest#* }
  key=${key//\'/}; key=${key//\"/}
  [[ $key == M-Space ]] && continue          # that is this finder itself

  label=""
  if [[ $cmd == *'#='* ]]; then
    label=${cmd##*#=}
    label=${label#"${label%%[![:space:]]*}"}
    cmd=${cmd%%#=*}
  fi
  cmd=${cmd%"${cmd##*[![:space:]]}"}
  [[ -n $label ]] || label=$cmd

  pk=$(pretty "$key")
  rows+=("$(printf '%-18s\t%s\t%s' "$pk" "$label" "$cmd")")

  fk=$(fzfkey "$key")
  [[ -n $fk ]] && binds+=(--bind "$fk:become(exec tmux $cmd)")
done < "$CONF"

((${#rows[@]})) || { echo "no 'bind -n' lines found in $CONF" >&2; exit 1; }

printf '%s\n' "${rows[@]}" | fzf \
  --delimiter='\t' --with-nth=1,2 --nth=1,2 \
  --prompt='keys > ' --info=inline --reverse --height=100% \
  --header=$'type to filter (try "alt+shift") · enter runs · press the real combo to run it directly · esc closes' \
  --preview='printf "%s\n" {3}' --preview-window=down,3,wrap \
  "${binds[@]}" \
  --bind='enter:become(exec tmux {3})' \
  --bind='esc:abort'
