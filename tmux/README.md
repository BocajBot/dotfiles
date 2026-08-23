# tmux

Prefixless, single-handed tmux config driven from kitty.

## Install

```sh
ln -sf "$PWD/tmux/tmux.conf" ~/.tmux.conf
mkdir -p ~/.config/tmux
ln -sf "$PWD"/tmux/scripts/*.sh ~/.config/tmux/

# plugins (no plugin manager needed)
mkdir -p ~/.tmux/plugins && cd ~/.tmux/plugins
git clone --depth 1 https://github.com/tmux-plugins/tmux-resurrect.git
git clone --depth 1 https://github.com/tmux-plugins/tmux-continuum.git
```

Requires `fzf` for the two pickers. `@resurrect-dir` in `tmux.conf` is an
absolute path — change it if your home directory differs.

To auto-start tmux from kitty, add to `~/.zshrc` **above** the Powerlevel10k
instant-prompt block (instant prompt redirects the console, and tmux then fails
with `open terminal failed: not a terminal`):

```zsh
if [[ -o interactive ]] && [[ -z "$TMUX" ]] && [[ -n "$KITTY_WINDOW_ID" ]]; then
  ~/.config/tmux/kitty-attach.sh
fi
```

## Keys

No prefix. Everything is reachable with the left hand, left Alt as modifier.

| Key | Action |
|---|---|
| `alt+space` | command finder — every binding, searchable |
| `alt+w/a/s/d` | move between panes |
| `alt+shift+w/a/s/d` | resize pane |
| `alt+e` | split pane, direction picked from the pane's shape (autotiling) |
| `alt+f` | merge another window in as a pane |
| `alt+b` | eject pane into its own window |
| `alt+z` / `alt+x` / `alt+v` | zoom / close (enter or `x` confirms) / swap |
| `alt+t` / `alt+q` / `alt+r` / `alt+1..9` | new window / prev / next / jump |
| `alt+c` / ``alt+` `` | session picker / last session |
| `alt+g` / `alt+shift+f` | scrollback / search scrollback |
| `alt+shift+c` / `alt+shift+v` | save snapshot / restore snapshot |
| `alt+shift+r` / `alt+shift+e` | reload config / edit this config |

## Scripts

- `tmux-keys.sh` — fzf command finder. Parses `bind -n` lines out of
  `tmux.conf` at open time, so the list never goes stale. Labels come from a
  trailing `#= some label` comment on the bind line.
- `smart-split.sh` — autotiling. Splits along the pane's longer side; terminal
  cells are ~2x taller than wide, so the test is `width > height * 2`.
- `session-picker.sh` — fzf session switcher. Filters on session *and* window
  names, creates a session if the query matches nothing, `ctrl-x` kills.
- `kitty-attach.sh` — attaches a new kitty window to tmux, waiting for
  continuum's async restore first so it doesn't race it and land in an empty
  session.

## Gotchas

- `display-menu` rows with an empty key *and* empty command crash the tmux
  server. Every row needs both.
- `alt+d` and `alt+t` shadow readline's `kill-word` and `transpose-words`.
- Persistence restores layout, working directories and window names — not
  running processes. Only `@resurrect-processes` are relaunched, cold.
