#!/usr/bin/env bash
# Autotiling split, i3 style: split the focused pane along its LONGER side.
#
# Terminal cells here are ~2.3x taller than wide, so a pane that "looks" square
# has width ~= 2.3 * height. Compare against that, not against raw equality or
# a 2.0 guess, or near-square panes split the wrong way.
#
# Independently: below MIN_H_WIDTH columns a side-by-side split leaves both
# halves too narrow to read, so stack regardless of shape.
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

# wide pane -> side-by-side (-h); tall or narrow pane -> stacked (-v)
MIN_H_WIDTH=${SMART_SPLIT_MIN_H_WIDTH:-160}   # both halves stay >= 80 cols
CELL_RATIO=${SMART_SPLIT_CELL_RATIO:-23}      # cell height / width, tenths

if (( w >= MIN_H_WIDTH && w * 10 > h * CELL_RATIO )); then
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
