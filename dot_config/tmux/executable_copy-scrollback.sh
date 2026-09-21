#!/usr/bin/env bash
# Copy a pane's whole scrollback (history + current screen) to the system
# clipboard. Bound to alt+shift+g in ~/.tmux.conf.
#
#   copy-scrollback.sh [pane-id]   defaults to the active pane
set -uo pipefail

pane=${1:-}
[[ -n $pane ]] || pane=$(tmux display-message -p '#{pane_id}')

if command -v wl-copy >/dev/null 2>&1; then
  copy=(wl-copy)
elif command -v xclip >/dev/null 2>&1; then
  copy=(xclip -selection clipboard)
elif command -v xsel >/dev/null 2>&1; then
  copy=(xsel --clipboard --input)
else
  tmux display-message "no clipboard tool (wl-copy / xclip / xsel)"
  exit 1
fi

# -S - starts at the oldest line still in history, -J unwraps lines that tmux
# hard-wrapped at the pane edge. sed drops the padding -J leaves on line ends;
# $( ) drops the blank lines below the cursor.
text=$(tmux capture-pane -pJ -S - -t "$pane" | sed 's/[[:space:]]*$//')

if [[ -z $text ]]; then
  tmux display-message "scrollback empty"
  exit 0
fi

printf '%s\n' "$text" | "${copy[@]}"
tmux display-message "scrollback copied: $(wc -l <<<"$text") lines"
