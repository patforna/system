#!/usr/bin/env bash
set -euo pipefail
# Symlink public and private dotfiles into $HOME.

PUBLIC="${HOME}/github/system/dotfiles"
PRIVATE="${HOME}/Drive/system"

# --- Helpers ---

link() {
  local src="$1" dest="$2"
  if [[ ! -e "$src" ]]; then
    echo "  SKIP  $src (not found)"
    return
  fi
  mkdir -p "$(dirname "$dest")"
  ln -sf "$src" "$dest"
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
echo "Public:  ${PUBLIC}"
echo "Private: ${PRIVATE}"
echo ""

# --- Ensure local directories exist ---
echo "--- Directories ---"
ensure_local_dir "${HOME}/.config"
ensure_local_dir "${HOME}/.claude"
ensure_local_dir "${HOME}/.claude/skills"
ensure_local_dir "${HOME}/.codex"
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
link "${PRIVATE}/ssh-config.local"                 "${HOME}/.ssh/config.local"
echo ""

# --- XDG Config ---
echo "--- XDG Config ---"
link "${PUBLIC}/.config/ghostty/config"            "${HOME}/.config/ghostty/config"
link "${PUBLIC}/.config/nvim/init.lua"             "${HOME}/.config/nvim/init.lua"
link "${PUBLIC}/.config/nvim/lazy-lock.json"       "${HOME}/.config/nvim/lazy-lock.json"
link "${PUBLIC}/.config/starship.toml"             "${HOME}/.config/starship.toml"
link "${PUBLIC}/.config/atuin/config.toml"         "${HOME}/.config/atuin/config.toml"
link "${PUBLIC}/.config/btop/btop.conf"            "${HOME}/.config/btop/btop.conf"
link "${PUBLIC}/.config/gh/config.yml"             "${HOME}/.config/gh/config.yml"
link "${PUBLIC}/.config/git/ignore"                "${HOME}/.config/git/ignore"
link "${PUBLIC}/.config/fd/config"                 "${HOME}/.config/fd/config"
echo ""

# --- Claude Code ---
echo "--- Claude Code ---"
ensure_local_dir "${HOME}/.claude/projects"
link "${PUBLIC}/.claude/CLAUDE.md"                 "${HOME}/.claude/CLAUDE.md"
link "${PUBLIC}/.claude/statusline-command.sh"     "${HOME}/.claude/statusline-command.sh"

# Skills — symlink each skill dir from private location
if [[ -d "${PRIVATE}/skills" ]]; then
  for skill in "${PRIVATE}/skills"/*/; do
    skill_name=$(basename "$skill")
    ln -sfn "$skill" "${HOME}/.claude/skills/${skill_name}"
    echo "  OK    ~/.claude/skills/${skill_name}"
  done
fi
echo ""

# --- VS Code ---
echo "--- VS Code ---"
link "${PUBLIC}/vscode-settings.json"              "${HOME}/Library/Application Support/Code/User/settings.json"
link "${PUBLIC}/vscode-keybindings.json"           "${HOME}/Library/Application Support/Code/User/keybindings.json"
echo ""

# --- Codex ---
echo "--- Codex ---"
link "${PUBLIC}/.codex/config.toml"                "${HOME}/.codex/config.toml"
echo ""

echo "=== Done ==="
