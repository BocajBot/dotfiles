#!/usr/bin/env bash
# Autotiling split, i3 style: split the focused pane along its LONGER side.
#
# Terminal cells are roughly twice as tall as they are wide, so a pane that
# "looks" square has width ~= 2 * height. Compare against that, not against
# raw equality, or every split comes out horizontal.
#
#   mode "split"  -> new shell in this pane (default)
#   mode "join"   -> pull window $2 in as a pane instead
set -uo pipefail

mode=${1:-split}
src=${2:-}

# tmux sets TMUX_PANE for run-shell, so act on the pane the key was pressed in
# rather than on whatever pane happens to be "current" server-wide.
pane=${TMUX_PANE:-}
target=()
[[ -n $pane ]] && target=(-t "$pane")

read -r w h <<<"$(tmux display-message "${target[@]}" -p '#{pane_width} #{pane_height}')"

# wide pane -> side-by-side (-h); tall pane -> stacked (-v)
if (( w > h * 2 )); then
  dir=-h
else
  dir=-v
fi

case $mode in
  join)
    [[ -n $src ]] || { tmux display-message "smart-split: no source window"; exit 1; }
    tmux join-pane "$dir" "${target[@]}" -s "$src"
    ;;
  *)
    tmux split-window "$dir" "${target[@]}" -c "#{pane_current_path}"
    ;;
esac
