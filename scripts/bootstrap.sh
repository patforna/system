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
if ! gh auth status &>/dev/null 2>&1; then
  echo "--- GitHub Auth ---"
  gh auth login
  echo ""
fi

# --- Cursor Extensions ---
# brew bundle only installs extensions into VS Code (via the `vscode` directive).
# Cursor is a VS Code fork that uses the same extension format but a separate
# extensions directory (~/.cursor/extensions/). Mirror VS Code extensions there.
if command -v cursor &>/dev/null; then
  echo "--- Cursor Extensions ---"
  grep '^vscode ' "${HOME}/github/system/Brewfile" | sed 's/^vscode "\(.*\)"/\1/' | while read -r ext; do
    cursor --install-extension "$ext" 2>/dev/null || echo "  WARN  $ext failed"
  done
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
fi
echo "  OK"
echo ""

# --- Claude Settings ---
echo "--- Claude Settings ---"
mkdir -p "$HOME/.claude"
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
echo "  OK    ~/.claude/settings.json"
echo ""

# --- Drift Check (weekly launchd job) ---
echo "--- Drift Check ---"
PLIST_SRC="${HOME}/github/system/com.patric.drift-check.plist"
PLIST_DEST="${HOME}/Library/LaunchAgents/com.patric.drift-check.plist"
if [[ -f "$PLIST_SRC" ]]; then
  mkdir -p "${HOME}/Library/LaunchAgents"
  cp "$PLIST_SRC" "$PLIST_DEST"
  launchctl bootout "gui/$(id -u)" "$PLIST_DEST" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST"
  echo "  OK    drift-check runs weekly (Mondays 10 AM)"
else
  echo "  SKIP  $PLIST_SRC not found"
fi
echo ""

# --- Reminders ---
echo "=== Done ==="
echo ""
echo "Manual steps:"
echo "  1. Download SSH key from 1Password (if not done above)"
echo "  2. VS Code → Cmd+Shift+P → 'Settings Sync: Turn Off'"
echo "  3. Set up Trackpad, Keyboard shortcuts, Language in System Settings"
