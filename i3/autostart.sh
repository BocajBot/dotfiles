#!/usr/bin/env bash
set -euo pipefail

run_once() {
  local key="$1"; shift
  local stamp="/tmp/i3-${key}.stamp"
  [[ -e "$stamp" ]] && return 0
  "$@" &
  touch "$stamp"
}

run_if_missing() {
  local proc="$1"; shift
  pgrep -x "$proc" >/dev/null 2>&1 || "$@" &
}

# XDG autostart (run once per boot)
run_once dex dex --autostart --environment i3

# Tray / daemons
run_if_missing nm-applet nm-applet
run_if_missing dunst dunst
run_if_missing picom picom -b
run_if_missing flameshot flameshot
run_if_missing caffeine caffeine
run_if_missing arch-audit-gtk arch-audit-gtk

# Your extras
run_if_missing solaar /usr/bin/solaar -w hide
run_if_missing synergy synergy %U
numlockx on >/dev/null 2>&1 || true
~/.fehbg &

# Display/layout helpers
run_if_missing autotiling autotiling
xlayoutdisplay >/dev/null 2>&1 || true

# Power / screensaver behavior
pulseaudio --start >/dev/null 2>&1 || true
xset s off -dpms

