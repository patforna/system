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
  zsh-autosuggestions zsh-syntax-highlighting shellcheck figlet git-crypt

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
gh_install "rhysd/actionlint"    "actionlint_.*_linux_${ARCH}\\.tar\\.gz"            actionlint
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

# rumdl (markdown linter) — TAD `just check-all` (md-check/md-format) calls it bare on PATH
export PATH="$HOME/.local/bin:$PATH"
if ! command -v rumdl &>/dev/null; then
  echo "  GET   rumdl"
  uv tool install rumdl > /dev/null 2>&1
else
  echo "  SKIP  rumdl"
fi

if ! command -v bun &>/dev/null; then
  echo "  GET   bun"
  curl -fsSL https://bun.sh/install | bash > /dev/null 2>&1
else
  echo "  SKIP  bun"
fi
# bun installs to ~/.bun/bin and only patches the interactive shell rc; symlink into
# ~/.local/bin (on PATH for non-interactive shells too) so dagu / just / auto-task find it.
mkdir -p "$HOME/.local/bin"
[[ -x "$HOME/.bun/bin/bun" ]] && ln -sf "$HOME/.bun/bin/bun" "$HOME/.local/bin/bun"
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

# --- Codex CLI (the codex@openai-codex plugin wraps the global `codex` binary) ---
echo "--- Codex CLI ---"
mkdir -p "$HOME/.local/bin"
# user-writable npm prefix → `npm -g` needs no sudo and lands in ~/.local/bin (on PATH,
# incl. non-interactive shells). A fresh box's default prefix is /usr, which would EACCES.
[[ "$(npm config get prefix)" == "$HOME/.local" ]] || npm config set prefix "$HOME/.local"
if ! command -v codex &>/dev/null; then
  npm install -g @openai/codex
  echo "  OK    codex $(codex --version 2>/dev/null || echo installed)"
else
  echo "  SKIP  codex $(codex --version 2>/dev/null)"
fi
echo ""

# --- System scripts on PATH ---
# CLI tools in scripts/ (+ private/scripts/ once unlocked) are on the interactive .zshrc PATH only;
# symlink them into ~/.local/bin so non-interactive harness/just/dagu resolve them (claude-replay,
# drift-check, …) — same reason as the bun symlink above. Convention: user-facing tools are
# extensionless; *.sh are internal (this script, dot_files, dagu jobs) and must NOT land on PATH.
echo "--- System scripts ---"
mkdir -p "$HOME/.local/bin"
for d in "$REPO_DIR/scripts" "$REPO_DIR/private/scripts"; do
  [[ -d "$d" ]] || continue
  for f in "$d"/*; do
    [[ -f "$f" && -x "$f" ]] || continue
    [[ "$f" == *.sh ]] && continue
    # skip still-encrypted git-crypt blobs (private/ before `git-crypt unlock`)
    [[ "$(head -c 10 "$f" | tr -d '\0')" == GITCRYPT* ]] && continue
    ln -sf "$f" "$HOME/.local/bin/$(basename "$f")"
  done
done
echo "  OK    scripts -> ~/.local/bin"
echo ""

# --- Playwright e2e system libs (TAD frontend / `just check-all`) ---
# bun install fetches the chromium binary but not its OS libs (libatk, libcups, libgbm, mesa…);
# without them e2e dies with `libatk-1.0.so.0`. install-deps apt-installs the set.
echo "--- Playwright deps ---"
if command -v bun &>/dev/null; then
  sudo env "PATH=$PATH" DEBIAN_FRONTEND=noninteractive bunx playwright install-deps chromium > /dev/null 2>&1 \
    && echo "  OK    playwright chromium deps" \
    || echo "  WARN  playwright install-deps failed — run 'sudo bunx playwright install-deps chromium'"
else
  echo "  SKIP  playwright deps (bun missing)"
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
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  },
  "statusLine": {
    "type": "command",
    "command": "/bin/bash $HOME/.claude/statusline-command.sh",
    "padding": 0
  },
  "enabledPlugins": {
    "context7@claude-plugins-official": true,
    "github@claude-plugins-official": true,
    "skill-creator@claude-plugins-official": true,
    "codex@openai-codex": true
  },
  "extraKnownMarketplaces": {
    "anthropic-agent-skills": {
      "source": {
        "source": "github",
        "repo": "anthropics/skills"
      }
    },
    "openai-codex": {
      "source": {
        "source": "github",
        "repo": "openai/codex-plugin-cc"
      }
    }
  },
  "effortLevel": "high",
  "skipDangerousModePermissionPrompt": true,
  "editorMode": "vim",
  "mcpServers": {
    "notion": {
      "type": "http",
      "url": "https://mcp.notion.com/mcp"
    }
  },
  "skipAutoPermissionPrompt": true
}
SETTINGS
echo "  OK    $HOME/.claude/settings.json (generated)"
echo ""

# --- Remote config parity (informational) ---
# Surface any divergence between remote/ and the Mac dotfiles at provision time.
# Non-fatal: the fix always lives on the Mac, but flag it while standing up the box.
echo "--- Remote config parity ---"
if drift_out=$("$REPO_DIR/scripts/drift-check" --remote 2>&1); then
  echo "  OK    remote/ in sync with Mac dotfiles"
else
  echo "  WARN  remote/ differs from Mac dotfiles:"
  echo "$drift_out" | sed -n 's/^  - /        - /p'
fi
echo ""

echo "=== Done ==="
