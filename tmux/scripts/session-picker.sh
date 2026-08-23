#!/usr/bin/env bash
# fzf session switcher for tmux.
#
#   type            filter by session name, or by any window name inside it
#   enter           switch to the highlighted session
#   enter on a name that matches nothing  ->  create a session with that name
#   ctrl-x          kill the highlighted session
#   esc             close
#
# Runs inside display-popup, so $TMUX is set and switch-client hits the right client.
set -uo pipefail

SELF=$(readlink -f "$0")
current=$(tmux display-message -p '#{session_name}')

list() {
  # name <TAB> pretty line;  windows listed so they are searchable too
  tmux list-sessions -F '#{session_name}#{?session_attached, (attached),}' 2>/dev/null |
  while IFS= read -r line; do
    name=${line%% *}
    wins=$(tmux list-windows -t "$name" -F '#{window_name}' 2>/dev/null | paste -sd' ' -)
    marker='  '
    [[ $name == "$current" ]] && marker='* '
    printf '%s\t%s%-18s %s\n' "$name" "$marker" "$line" "$wins"
  done
}

# reload mode, used by the kill binding below
if [[ ${1:-} == --list ]]; then list; exit 0; fi

sel=$(list | fzf \
  --delimiter='\t' --with-nth=2 --nth=2 \
  --prompt='session > ' --info=inline --reverse --height=100% \
  --print-query \
  --header=$'enter switches · type a new name + enter creates it · ctrl-x kills · esc closes' \
  --preview='tmux list-windows -t {1} -F "#{window_index}: #{window_name} (#{window_panes} panes)" 2>/dev/null' \
  --preview-window=down,40%,wrap \
  --bind="ctrl-x:execute-silent(tmux kill-session -t {1})+reload($SELF --list)" \
  --expect=enter)

[[ -z $sel ]] && exit 0

query=$(sed -n 1p <<<"$sel")
line=$(sed -n 3p <<<"$sel")
name=${line%%$'\t'*}

if [[ -n $name ]]; then
  tmux switch-client -t "$name"
elif [[ -n $query ]]; then
  # nothing matched: treat the query as a new session name
  tmux new-session -d -s "$query" && tmux switch-client -t "$query"
fi
