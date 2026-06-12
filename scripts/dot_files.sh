#!/usr/bin/env bash
set -euo pipefail
# Symlink public and private dotfiles into $HOME.

REPO="${HOME}/github/system"
PUBLIC="${REPO}/dotfiles"
PRIVATE="${REPO}/private"

# --- Helpers ---

link() {
  local src="$1" dest="$2"
  if [[ ! -e "$src" ]]; then
    echo "  SKIP  $src (not found)"
    return
  fi
  # ln -sfn into an existing REAL directory silently creates
  # dest/$(basename src) instead of replacing dest — refuse instead.
  if [[ -d "$dest" && ! -L "$dest" ]]; then
    echo "  WARN  $dest is a real directory — move it aside and re-run"
    return
  fi
  mkdir -p "$(dirname "$dest")"
  ln -sfn "$src" "$dest"
  echo "  OK    $dest"
}

# Convert old-style directory symlinks to local dirs.
ensure_local_dir() {
  local dir="$1"
  if [[ -L "$dir" ]]; then
    echo "  FIX   $dir: converting directory symlink -> local dir"
    rm "$dir"
  fi
  mkdir -p "$dir"
}

echo "=== Dotfiles Setup ==="
echo "Repo:    ${REPO}"
echo "Public:  ${PUBLIC}"
echo "Private: ${PRIVATE} (git-crypt encrypted)"
echo ""

# --- Ensure local directories exist ---
echo "--- Directories ---"
ensure_local_dir "${HOME}/.config"
ensure_local_dir "${HOME}/.claude"
echo ""

# --- Shell & Terminal ---
echo "--- Shell & Terminal ---"
link "${PUBLIC}/.zshrc"                            "${HOME}/.zshrc"
link "${PUBLIC}/.tmux.conf"                        "${HOME}/.tmux.conf"
echo ""

# --- Git ---
echo "--- Git ---"
link "${PUBLIC}/.gitconfig"                        "${HOME}/.gitconfig"
echo ""

# --- SSH ---
echo "--- SSH ---"
link "${PUBLIC}/.ssh-config"                       "${HOME}/.ssh/config"
# ~/.ssh/config.local is untracked, local-only (dev droplet IP, written by dev-up)
echo ""

# --- XDG Config ---
echo "--- XDG Config ---"
link "${PUBLIC}/.config/ghostty/config"            "${HOME}/.config/ghostty/config"
link "${PUBLIC}/.config/nvim"                      "${HOME}/.config/nvim"
link "${PUBLIC}/.config/starship.toml"             "${HOME}/.config/starship.toml"
link "${PUBLIC}/.config/atuin/config.toml"         "${HOME}/.config/atuin/config.toml"
link "${PUBLIC}/.config/btop/btop.conf"            "${HOME}/.config/btop/btop.conf"
link "${PUBLIC}/.config/gh/config.yml"             "${HOME}/.config/gh/config.yml"
link "${PUBLIC}/.config/lazygit/config.yml"        "${HOME}/.config/lazygit/config.yml"
link "${PUBLIC}/.config/git/ignore"                "${HOME}/.config/git/ignore"
link "${PUBLIC}/.config/fd/config"                 "${HOME}/.config/fd/config"
link "${PUBLIC}/.config/gcloud/configurations/config_default" "${HOME}/.config/gcloud/configurations/config_default"
link "${PUBLIC}/.config/espanso"                   "${HOME}/.config/espanso"
link "${PUBLIC}/.config/dagu/base.yaml"            "${HOME}/.config/dagu/base.yaml"
link "${REPO}/dagu"                                "${HOME}/.config/dagu/dags"
link "${PRIVATE}/gws/client_secret.json"          "${HOME}/.config/gws/client_secret.json"
link "${PRIVATE}/gws/.encryption_key"             "${HOME}/.config/gws/.encryption_key"
link "${PRIVATE}/gws/credentials.enc"             "${HOME}/.config/gws/credentials.enc"
echo ""

# --- App credentials (non-XDG) ---
echo "--- App credentials ---"
link "${PRIVATE}/msgvault/client_secret.json"     "${HOME}/.msgvault/client_secret.json"
echo ""

# --- Claude Code ---
echo "--- Claude Code ---"
ensure_local_dir "${HOME}/.claude/projects"
ensure_local_dir "${HOME}/.claude/memory"
link "${PRIVATE}/claude/CLAUDE.md"                 "${HOME}/.claude/CLAUDE.md"
link "${PRIVATE}/claude/memory/MEMORY.md"          "${HOME}/.claude/memory/MEMORY.md"
link "${PUBLIC}/.claude/statusline-command.sh"     "${HOME}/.claude/statusline-command.sh"

# Skills — symlink directory (individual skill symlinks are tracked in dotfiles)
link "${PUBLIC}/.claude/skills"                    "${HOME}/.claude/skills"
echo ""

# --- macOS app configs ---
echo "--- macOS app configs ---"
link "${PUBLIC}/vscode-settings.json"              "${HOME}/Library/Application Support/Code/User/settings.json"
link "${PUBLIC}/vscode-keybindings.json"           "${HOME}/Library/Application Support/Code/User/keybindings.json"
link "${PUBLIC}/.config/lazygit/config.yml"        "${HOME}/Library/Application Support/lazygit/config.yml"
echo ""

echo "=== Done ==="
