# dotfiles

Machine rebuild kit for CachyOS. Managed with [chezmoi](https://chezmoi.io).

## Rebuild a new machine

```sh
sh -c "$(curl -fsLS get.chezmoi.io/lb)" -- -b ~/.local/bin
~/.local/bin/chezmoi init --apply <REPO-URL>
bash ~/.local/share/chezmoi/setup.sh
```

`setup.sh` installs: official packages (`pkglist.txt`), AUR packages via yay
(`aurlist.txt`), rustup, nvm + Node LTS, uv.

## Day-to-day

```sh
chezmoi add ~/.zshrc          # track a changed/new file
chezmoi diff                  # what would change on apply
chezmoi apply                 # write managed files to $HOME
chezmoi cd                    # open source repo (git commit/push from there)
```

Refresh package lists after installing things:

```sh
cd $(chezmoi source-path)
pacman -Qqe | grep -vx "$(pacman -Qqm)" > pkglist.txt
pacman -Qqm > aurlist.txt
```

## Not covered

- `models/` (568G of weights) — re-download via `bin/hfget` / `models/download-selected-hf-models.sh`
- Steam library, Heroic games
- Secrets: `.ssh`, `.gnupg`, app logins, `~/.claude/.credentials.json`
- Docker volumes under `~/docker/`
