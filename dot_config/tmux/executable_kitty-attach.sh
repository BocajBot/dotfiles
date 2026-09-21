#!/usr/bin/env bash
# Land a new kitty window in tmux, cooperating with continuum's auto-restore.
#
# A tmux server with no sessions exits immediately, so we cannot just
# `start-server` and wait. Instead create a throwaway session (that boots the
# server, sources ~/.tmux.conf and fires continuum's restore), wait for the
# restored sessions to appear, attach to one of those, and drop the throwaway.
# Without the wait we would race the restore and land in an empty session while
# the restored ones sat unattached beside it.
#
# TMUX_SOCKET may be set to test against a throwaway server: TMUX_SOCKET=test ...
set -uo pipefail

tm() { if [[ -n ${TMUX_SOCKET:-} ]]; then tmux -L "$TMUX_SOCKET" "$@"; else tmux "$@"; fi; }

WAIT_MAX=${TMUX_RESTORE_WAIT:-12}      # seconds to allow for a restore
BOOTSTRAP=_bootstrap

sessions() { tm list-sessions -F '#{session_name}' 2>/dev/null; }

if ! tm has-session 2>/dev/null; then
  tm new-session -d -s "$BOOTSTRAP" 2>/dev/null || true
  waited=0
  while (( waited < WAIT_MAX )); do
    # anything other than the bootstrap session means the restore has landed
    if [[ -n $(sessions | grep -vx "$BOOTSTRAP") ]]; then
      sleep 2                          # let the remaining windows/panes land
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  # drop the throwaway once there is something real to attach to
  if [[ -n $(sessions | grep -vx "$BOOTSTRAP") ]]; then
    tm kill-session -t "$BOOTSTRAP" 2>/dev/null || true
  fi
fi

free=$(tm list-sessions -F '#{session_name} #{session_attached}' 2>/dev/null \
       | awk '$2 == 0 { print $1; exit }')

if [[ -n $free ]]; then
  cmd=(attach-session -t "$free")
else
  cmd=(new-session)
fi

if [[ -n ${TMUX_SOCKET:-} ]]; then
  echo "would run: tmux -L $TMUX_SOCKET ${cmd[*]}"
  tm list-sessions -F '  session #{session_name} attached=#{session_attached}' 2>/dev/null
else
  exec tmux "${cmd[@]}"
fi
