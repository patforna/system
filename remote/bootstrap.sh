#!/usr/bin/env bash
set -euo pipefail
# Bootstrap script for Ubuntu dev droplet. Installs all tools, links configs.

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARCH=$(dpkg --print-architecture)

case $ARCH in
  amd64) ARCH_GH="x86_64" ;;
  arm64) ARCH_GH="aarch64" ;;
  *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

echo "=== Remote Dev Bootstrap ==="
echo "Repo: $REPO_DIR"
echo "Arch: $ARCH ($ARCH_GH)"
echo ""

if [[ $EUID -eq 0 ]]; then
  echo "Run as a regular user with sudo access, not root."
  echo "  adduser patric && usermod -aG sudo patric"
  echo "  cp -r ~/.ssh /home/patric/.ssh && chown -R patric:patric /home/patric/.ssh"
  echo "  echo 'patric ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers.d/patric"
  echo "  su - patric"
  exit 1
fi

# --- Helper: install binary from GitHub release tarball ---
gh_install() {
  local repo="$1" pattern="$2" binary="$3"
  if command -v "$binary" &>/dev/null; then
    echo "  SKIP  $binary"
    return
  fi
  echo "  GET   $binary"
  local url tmp
  url=$(curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" \
    | jq -r --arg pat "$pattern" '.assets[] | select(.name | test($pat)) | .browser_download_url' | head -1)
  if [[ -z "$url" ]]; then
    echo "  FAIL  $binary — no matching release asset"
    return 1
  fi
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/archive.tar.gz" "$url"
  tar -xzf "$tmp/archive.tar.gz" -C "$tmp"
  sudo install "$(find "$tmp" -name "$binary" -type f | head -1)" /usr/local/bin/
  rm -rf "$tmp"
}

# --- System packages ---
echo "--- apt packages ---"
sudo apt-get update -qq
sudo apt-get install -y -qq \
  zsh tmux neovim git ripgrep bat fd-find btop jq curl unzip build-essential \
  zsh-autosuggestions zsh-syntax-highlighting

# Ubuntu ships bat as "batcat" and fd as "fdfind" — create symlinks
sudo ln -sf /usr/bin/batcat /usr/local/bin/bat 2>/dev/null || true
sudo ln -sf /usr/bin/fdfind /usr/local/bin/fd 2>/dev/null || true
echo ""

# --- Node.js (needed by Claude Code plugins like context7) ---
echo "--- Node.js ---"
if ! command -v node &>/dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
  sudo apt-get install -y -qq nodejs
  echo "  OK    node $(node --version)"
else
  echo "  SKIP  node $(node --version)"
fi
echo ""

# --- GitHub CLI ---
echo "--- GitHub CLI ---"
if ! command -v gh &>/dev/null; then
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
  echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
  sudo apt-get update -qq && sudo apt-get install -y -qq gh
else
  echo "  SKIP  gh"
fi
echo ""

# --- Tools from GitHub releases ---
echo "--- GitHub releases ---"
gh_install "junegunn/fzf"        "fzf-.*-linux_${ARCH}\\.tar\\.gz"                   fzf
gh_install "dandavison/delta"    "delta-.*-${ARCH_GH}-unknown-linux-musl\\.tar\\.gz"  delta
gh_install "jesseduffield/lazygit" "lazygit_.*_linux_${ARCH_GH}\\.tar\\.gz"           lazygit
gh_install "eza-community/eza"       "eza_${ARCH_GH}-unknown-linux-gnu\\.tar\\.gz"        eza
if ! command -v stylua &>/dev/null; then
  echo "  GET   stylua"
  url=$(curl -fsSL "https://api.github.com/repos/JohnnyMorganz/StyLua/releases/latest" \
    | jq -r --arg pat "stylua-linux-${ARCH_GH}\\.zip" '.assets[] | select(.name | test($pat)) | .browser_download_url' | head -1)
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/stylua.zip" "$url"
  unzip -q "$tmp/stylua.zip" -d "$tmp"
  sudo install "$tmp/stylua" /usr/local/bin/
  rm -rf "$tmp"
else
  echo "  SKIP  stylua"
fi
echo ""

# --- Tools from curl installers ---
echo "--- Curl installers ---"
if ! command -v starship &>/dev/null; then
  echo "  GET   starship"
  curl -sS https://starship.rs/install.sh | sh -s -- -y > /dev/null
else
  echo "  SKIP  starship"
fi

if ! command -v atuin &>/dev/null; then
  echo "  GET   atuin"
  curl --proto '=https' --tlsv1.2 -LsSf https://setup.atuin.sh | sh > /dev/null 2>&1
else
  echo "  SKIP  atuin"
fi

if ! command -v zoxide &>/dev/null; then
  echo "  GET   zoxide"
  curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh > /dev/null 2>&1
else
  echo "  SKIP  zoxide"
fi

if ! command -v just &>/dev/null; then
  echo "  GET   just"
  curl -sSfL https://just.systems/install.sh | bash -s -- --to /usr/local/bin > /dev/null 2>&1
else
  echo "  SKIP  just"
fi

if ! command -v uv &>/dev/null; then
  echo "  GET   uv"
  curl -LsSf https://astral.sh/uv/install.sh | sh > /dev/null 2>&1
else
  echo "  SKIP  uv"
fi
echo ""

# --- Claude Code ---
echo "--- Claude Code ---"
if ! command -v claude &>/dev/null; then
  curl -fsSL https://claude.ai/install.sh | bash
  echo "  OK    claude"
else
  echo "  SKIP  claude"
fi
echo ""

# --- Tmux Plugin Manager ---
echo "--- TPM ---"
TPM_DIR="$HOME/.tmux/plugins/tpm"
if [[ ! -d "$TPM_DIR" ]]; then
  echo "  GET   tpm"
  git clone --depth 1 https://github.com/tmux-plugins/tpm "$TPM_DIR"
else
  echo "  SKIP  tpm"
fi
# Install plugins — needs a tmux server with TMUX_PLUGIN_MANAGER_PATH set
tmux start-server 2>/dev/null || true
tmux set-environment -g TMUX_PLUGIN_MANAGER_PATH "$HOME/.tmux/plugins/" 2>/dev/null || true
"$TPM_DIR/bin/install_plugins" || echo "  WARN  TPM install failed (will install on first tmux start)"
echo ""

# --- Default shell ---
if [[ "$SHELL" != *zsh ]]; then
  echo "--- Default shell ---"
  chsh -s "$(which zsh)"
  echo "  OK    zsh"
  echo ""
fi

# --- Dotfiles ---
echo "--- Dotfiles ---"
link() {
  local src="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  ln -sf "$src" "$dest"
  echo "  OK    $dest"
}

# Linux-specific configs
link "$REPO_DIR/remote/zshrc"      "$HOME/.zshrc"
link "$REPO_DIR/remote/tmux.conf"  "$HOME/.tmux.conf"
link "$REPO_DIR/remote/gitconfig"  "$HOME/.gitconfig"

# Shared configs (identical on Mac + Linux)
link "$REPO_DIR/dotfiles/.config/starship.toml"       "$HOME/.config/starship.toml"
link "$REPO_DIR/dotfiles/.config/atuin/config.toml"   "$HOME/.config/atuin/config.toml"
link "$REPO_DIR/dotfiles/.config/nvim/init.lua"       "$HOME/.config/nvim/init.lua"
link "$REPO_DIR/dotfiles/.config/nvim/lazy-lock.json" "$HOME/.config/nvim/lazy-lock.json"
link "$REPO_DIR/dotfiles/.config/btop/btop.conf"      "$HOME/.config/btop/btop.conf"
link "$REPO_DIR/dotfiles/.config/gh/config.yml"       "$HOME/.config/gh/config.yml"
link "$REPO_DIR/dotfiles/.config/git/ignore"          "$HOME/.config/git/ignore"
link "$REPO_DIR/dotfiles/.config/fd/config"           "$HOME/.config/fd/config"

# Claude Code
mkdir -p "$HOME/.claude/projects"
link "$REPO_DIR/dotfiles/.claude/statusline-command.sh" "$HOME/.claude/statusline-command.sh"
if [[ -d "$REPO_DIR/dotfiles/.claude/skills" ]]; then
  ln -sfn "$REPO_DIR/dotfiles/.claude/skills"             "$HOME/.claude/skills"
  echo "  OK    $HOME/.claude/skills"
fi

# Claude settings — generated because the statusline path is machine-specific
cat > "$HOME/.claude/settings.json" <<'SETTINGS'
{
  "model": "opus",
  "statusLine": {
    "type": "command",
    "command": "/bin/bash $HOME/.claude/statusline-command.sh"
  },
  "mcpServers": {
    "notion": {
      "type": "http",
      "url": "https://mcp.notion.com/mcp"
    }
  },
  "enabledPlugins": {
    "context7@claude-plugins-official": true,
    "github@claude-plugins-official": true
  },
  "skipDangerousModePermissionPrompt": true
}
SETTINGS
echo "  OK    $HOME/.claude/settings.json (generated)"
echo ""

echo "=== Done ==="
