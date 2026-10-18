#!/usr/bin/env bash
# Send the local clipboard *image* to the host this pane is ssh'd into, then
# paste the remote file path into the pane. Claude Code / pi on the far side
# turn a pasted image path into an attachment. Bound to alt+shift+v.
#
# Text doesn't need this: the terminal's normal paste already types it
# through ssh. Needs key-based ssh to the host (run-shell can't answer a
# password prompt). Works on macOS and on Linux (Wayland or X11).
#
#   paste-image.sh <pane-id>            required: never guesses a pane
#   DRY_RUN=1 paste-image.sh <pane-id>  stop before uploading, print what it found
#
# Written for bash 3.2 too (macOS /bin/bash), hence no -u and no mapfile.
set -o pipefail

pane=${1:-}
[[ $pane == %* ]] || { echo "usage: ${0##*/} <pane-id, e.g. %3>" >&2; exit 2; }
msg() { tmux display-message -d 4000 "paste-image: $*"; }

tmp=$(mktemp "${TMPDIR:-/tmp}/paste-image.XXXXXX") || exit 1
err=$(mktemp "${TMPDIR:-/tmp}/paste-image.XXXXXX") || exit 1
trap 'rm -f "$tmp" "$err"' EXIT

# 1. Clipboard image -> PNG ------------------------------------------------
case $(uname -s) in
  Darwin)
    osascript \
      -e "set f to open for access POSIX file \"$tmp\" with write permission" \
      -e 'set eof f to 0' \
      -e 'write (the clipboard as «class PNGf») to f' \
      -e 'close access f' >/dev/null 2>&1
    ;;
  *)
    # Ask for image/png only if the owner offers it: an xclip-owned text
    # selection answers *any* target with its text.
    if [[ -n ${WAYLAND_DISPLAY:-} ]] && command -v wl-paste >/dev/null 2>&1; then
      wl-paste --list-types 2>/dev/null | grep -qx image/png &&
        wl-paste --no-newline --type image/png >"$tmp" 2>/dev/null
    elif [[ -n ${DISPLAY:-} ]] && command -v xclip >/dev/null 2>&1; then
      xclip -selection clipboard -target TARGETS -out 2>/dev/null | grep -qx image/png &&
        xclip -selection clipboard -target image/png -out >"$tmp" 2>/dev/null
    else
      msg "no clipboard tool (wl-paste needs WAYLAND_DISPLAY, xclip needs DISPLAY)"
      exit 1
    fi
    ;;
esac
# Must actually be a PNG (magic bytes 89 50 4E 47 0D 0A 1A 0A).
if [[ $(head -c 8 "$tmp" | od -An -tx1 | tr -d ' \n') != 89504e470d0a1a0a ]]; then
  msg "clipboard has no image (for text, just paste normally)"
  exit 0
fi

# 2. Find the ssh in the foreground of this pane ------------------------------
# (an ssh some program runs in the background there isn't the one you see)
sshpid=
root=$(tmux display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null)
[[ -n $root ]] || { msg "no such pane: $pane"; exit 1; }
queue=("$root")
while ((${#queue[@]})); do
  p=${queue[0]}
  queue=("${queue[@]:1}")
  comm=$(ps -o comm= -p "$p" 2>/dev/null)
  if [[ ${comm##*/} == ssh ]]; then
    read -r pg tpg <<<"$(ps -o pgid=,tpgid= -p "$p" 2>/dev/null)"
    if [[ -n $pg && $pg == "$tpg" ]]; then sshpid=$p; break; fi
  fi
  for c in $(pgrep -P "$p"); do queue+=("$c"); done
done
if [[ -z $sshpid ]]; then
  msg "no ssh in this pane (a local Claude Code pastes images itself)"
  exit 0
fi

# 3. Reuse its options + destination, drop any remote command ---------------
args=() split_argv=
if [[ -r /proc/$sshpid/cmdline ]]; then          # Linux: exact argv
  while IFS= read -r -d '' a; do args+=("$a"); done <"/proc/$sshpid/cmdline"
else                                             # macOS: ps drops the quoting,
  read -r -a args <<<"$(ps -o args= -p "$sshpid")"  # so values with spaces split
  split_argv=1
fi
args=("${args[@]:1}")

# As in OpenSSH, options may come before *and* after the destination; the
# first plain word after the destination starts the remote command.
takes_arg=BbcDEeFIiJLlmOoPpQRSWw                 # ssh options with a value
opts=() dest=
while ((${#args[@]})); do
  a=${args[0]}
  args=("${args[@]:1}")
  if [[ $a == -- ]]; then
    [[ -n $dest ]] || dest=${args[0]:-}
    break
  fi
  if [[ $a != -?* ]]; then
    [[ -n $dest ]] && break
    dest=$a
    continue
  fi
  opts+=("$a")
  # In a cluster like -Ap the value is the next word; in -p22 it's attached.
  flags=${a#-} i=0
  while ((i < ${#flags})); do
    c=${flags:i:1}
    if [[ $takes_arg == *"$c"* ]]; then
      val=${flags:i+1}
      if [[ -z $val ]] && ((${#args[@]})); then
        val=${args[0]}
        opts+=("$val")
        args=("${args[@]:1}")
      fi
      # "-o 'Key value'" arrives from macOS ps as two words; don't guess.
      if [[ $c == o && -n $split_argv && $val != *=* ]]; then
        msg "can't read this ssh's options on macOS (-o with a space?); use -o Key=value"
        exit 0
      fi
      break
    fi
    i=$((i + 1))
  done
done
[[ -n $dest ]] || { msg "couldn't parse the ssh destination"; exit 0; }

if [[ -n ${DRY_RUN:-} ]]; then
  printf 'dest=%s opts=(' "$dest"
  printf '[%s]' ${opts[@]+"${opts[@]}"}
  printf ') png=%s bytes\n' "$(wc -c <"$tmp" | tr -d ' ')"
  exit 0
fi

# 4. Upload; the remote prints the absolute path it wrote -------------------
# sh -c so it also works when the remote login shell is fish; $$ keeps two
# pastes in the same second apart.
remote="sh -c 'd=/tmp/paste-image-\$(id -u); mkdir -p \"\$d\" && chmod 700 \"\$d\" && f=\"\$d/clip-\$(date +%Y%m%d-%H%M%S)-\$\$.png\" && cat >\"\$f\" && printf %s \"\$f\"'"
# Our -o settings go first: for -o, ssh keeps the first value it sees. -T goes
# last: between -t and -T the last one wins. Forwardings would collide with
# the ones the interactive session already holds.
rpath=$(ssh -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 \
  -o ServerAliveCountMax=2 -o ClearAllForwardings=yes -o RemoteCommand=none \
  ${opts[@]+"${opts[@]}"} -T -- "$dest" "$remote" <"$tmp" 2>"$err")
if [[ $? -ne 0 || $rpath != /*.png ]]; then
  msg "upload to $dest failed: $(tail -n 1 "$err")"
  exit 0
fi

# 5. Paste the path as a bracketed paste, like dropping a file on the terminal
tmux set-buffer -b paste-image -- "$rpath " \; paste-buffer -p -d -b paste-image -t "$pane"
msg "sent $(($(wc -c <"$tmp") / 1024)) KB -> $dest:$rpath"
