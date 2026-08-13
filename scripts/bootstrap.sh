#!/usr/bin/env bash
set -euo pipefail

echo "=== Mac Bootstrap ==="
echo ""

# --- Homebrew ---
if ! command -v brew &>/dev/null; then
  echo "--- Installing Homebrew ---"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
else
  echo "--- Homebrew: already installed ---"
fi

# --- Packages ---
echo "--- Installing packages from Brewfile ---"
brew bundle install --file="${HOME}/github/system/Brewfile"
echo ""

# --- Claude Code ---
if ! command -v claude &>/dev/null; then
  echo "--- Installing Claude Code ---"
  curl -fsSL https://claude.ai/install.sh | sh
else
  echo "--- Claude Code: already installed ---"
fi
echo ""

# --- msgvault ---
if ! command -v msgvault &>/dev/null; then
  echo "--- Installing msgvault ---"
  curl -fsSL https://msgvault.io/install.sh | bash
else
  echo "--- msgvault: already installed ---"
fi
# We use our own OAuth client (lucid-box-490714-e8, In Production) instead of
# msgvault's upstream Testing-mode client — avoids 7-day refresh-token expiry.
# client_secret.json is symlinked by dot_files.sh; the token is machine-local.
if [[ -e "${HOME}/.msgvault/client_secret.json" && ! -f "${HOME}/.msgvault/tokens/patric.fornasier@gmail.com.json" ]]; then
  echo "  NOTE  No msgvault token. Run: msgvault add-account patric.fornasier@gmail.com --force"
fi
echo ""

# --- git-crypt ---
echo "--- git-crypt ---"
if command -v git-crypt &>/dev/null; then
  cd "${HOME}/github/system"
  # `git-crypt status` exits 0 whether the repo is locked or not, so it cannot
  # detect the locked state. The key file below is written by `git-crypt unlock`
  # and removed by `git-crypt lock` — its presence is the real unlock signal.
  if [[ -f .git/git-crypt/keys/default ]]; then
    echo "  OK    git-crypt already unlocked"
  else
    echo "  ACTION REQUIRED: Unlock private files with:"
    echo "    cd ~/github/system && git-crypt unlock /path/to/git-crypt-key"
    echo "  (Key is stored in 1Password as 'system-git-crypt-key')"
    echo ""
    echo "  Skipping dotfile setup until git-crypt is unlocked."
    exit 0
  fi
  cd -
else
  echo "  SKIP  git-crypt not installed (should have been installed via Brewfile)"
fi
echo ""

# --- Dotfiles ---
echo "--- Linking dotfiles ---"
bash "${HOME}/github/system/scripts/dot_files.sh"
echo ""

# --- SSH ---
if [[ ! -f "${HOME}/.ssh/id_ed25519" ]]; then
  echo "--- SSH ---"
  echo "  ACTION REQUIRED: Download id_ed25519 from 1Password to ~/.ssh/"
  echo "  Then run: chmod 600 ~/.ssh/id_ed25519 && ssh-add ~/.ssh/id_ed25519"
  echo ""
fi

# --- GitHub Auth ---
if ! gh auth status &>/dev/null; then
  echo "--- GitHub Auth ---"
  gh auth login
  echo ""
fi

# --- macOS Defaults ---
echo "--- macOS Defaults ---"
defaults write com.apple.dock static-only -bool true 2>/dev/null && killall Dock 2>/dev/null || true
defaults write com.apple.Finder FXPreferredViewStyle Nlsv 2>/dev/null && killall Finder 2>/dev/null || true
if command -v duti &>/dev/null; then
  duti -s com.microsoft.VSCode public.plain-text all 2>/dev/null || true
  duti -s com.microsoft.VSCode public.text all 2>/dev/null || true
  duti -s com.microsoft.VSCode public.source-code all 2>/dev/null || true
  # Per-extension overrides (some apps like Calibre claim specific extensions)
  while IFS=' ' read -r ext bundle_id; do
    [[ -z "$ext" || "$ext" == \#* ]] && continue
    duti -s "$bundle_id" "$ext" all 2>/dev/null || true
  done < "${HOME}/github/system/scripts/file-associations.conf"
fi
echo "  OK"
echo ""

# --- Claude Settings ---
echo "--- Claude Settings ---"
mkdir -p "$HOME/.claude"
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
    "github@claude-plugins-official": true
  },
  "effortLevel": "high",
  "skipDangerousModePermissionPrompt": true,
  "mcpServers": {
    "notion": {
      "type": "http",
      "url": "https://mcp.notion.com/mcp"
    }
  },
  "skipAutoPermissionPrompt": true
}
SETTINGS
echo "  OK    ~/.claude/settings.json"
echo ""

# --- Dagu Scheduler ---
echo "--- Dagu Scheduler ---"
if command -v dagu &>/dev/null; then
  if pgrep -qf "dagu start-all"; then
    echo "  OK    dagu scheduler already running"
  else
    echo "  NOTE  Start Dagu with: dagu start-all"
  fi
  echo "  Workflows: $(ls "${HOME}/github/system/dagu"/*.yaml | xargs -n1 basename | sed 's/\.yaml$//' | paste -sd, - | sed 's/,/, /g')"
else
  echo "  SKIP  dagu not installed (check Brewfile)"
fi
echo ""

# --- Login Items ---
echo "--- Login Items ---"
login_items=("ActivityWatch" "Maccy" "Rectangle")
for app in "${login_items[@]}"; do
  if [[ -d "/Applications/${app}.app" ]]; then
    if osascript -e "tell application \"System Events\" to get the name of every login item" 2>/dev/null | grep -q "$app"; then
      echo "  OK    ${app} already in login items"
    else
      osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"/Applications/${app}.app\", hidden:false}" 2>/dev/null
      echo "  ADD   ${app} added to login items"
    fi
  else
    echo "  SKIP  ${app} not installed"
  fi
done
echo ""

# --- Reminders ---
echo "=== Done ==="
echo ""
echo "Manual steps:"
echo "  1. Download SSH key from 1Password (if not done above)"
echo "  2. Unlock git-crypt: cd ~/github/system && git-crypt unlock /path/to/key (key in 1Password)"
echo "  3. VS Code → Cmd+Shift+P → 'Settings Sync: Turn Off'"
echo "  4. Set up Trackpad, Keyboard shortcuts, Language in System Settings"
