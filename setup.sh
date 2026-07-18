#!/usr/bin/env bash
# Bootstrap a fresh CachyOS/Arch machine from this repo.
# Usage: run AFTER `chezmoi init --apply <repo-url>` (or run directly; it will
# install chezmoi and apply dotfiles first).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> chezmoi + dotfiles"
if ! command -v chezmoi >/dev/null; then
  sh -c "$(curl -fsLS get.chezmoi.io/lb)" -- -b "$HOME/.local/bin"
  export PATH="$HOME/.local/bin:$PATH"
fi
chezmoi apply

echo "==> official repo packages"
sudo pacman -Syu --needed - < "$REPO_DIR/pkglist.txt"

echo "==> AUR helper + AUR packages"
if ! command -v yay >/dev/null; then
  tmp="$(mktemp -d)"
  git clone https://aur.archlinux.org/yay-bin.git "$tmp/yay-bin"
  (cd "$tmp/yay-bin" && makepkg -si --noconfirm)
  rm -rf "$tmp"
fi
yay -S --needed - < "$REPO_DIR/aurlist.txt"

echo "==> toolchains not managed by pacman"
# rust
command -v rustup >/dev/null || curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
# node via nvm
if [ ! -d "$HOME/.nvm" ]; then
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | bash
  export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"
  nvm install --lts
fi
# uv (python env manager)
command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh

echo "==> done. Log out/in for shell + PATH changes."
echo "Not covered (re-download manually): models/, Steam library, .ssh keys, app logins."
