#!/usr/bin/env bash
set -uo pipefail

# Drift check: detect anything installed/changed on the system that isn't
# tracked in the Brewfile, dotfiles, or README.
#
# Exit 0 = no drift, exit 1 = drift detected.
# When run via launchd (or with --notify), sends an email summary.

BREWFILE="${HOME}/github/system/Brewfile"
DOTFILES="${HOME}/github/system/dotfiles"
PRIVATE="${HOME}/Drive/system"
DRIFT=()

# --- Helpers ---

section() { echo ""; echo "--- $1 ---"; }

drift() {
  local msg="$1"
  DRIFT+=("$msg")
  echo "  DRIFT  $msg"
}

ok() { echo "  OK     $1"; }

# --- Brew formulae ---
section "Brew formulae"
brewfile_formulae=$(grep '^brew ' "$BREWFILE" | sed 's/^brew "\(.*\)"/\1/' | sort)
installed_leaves=$(brew leaves 2>/dev/null | sort)
installed_all_formulae=$(brew list --formula 2>/dev/null | sort)
formulae_drift_count=${#DRIFT[@]}

# New top-level packages not in Brewfile
while IFS= read -r pkg; do
  [[ -z "$pkg" ]] && continue
  drift "formula '$pkg' installed but not in Brewfile"
done < <(comm -23 <(echo "$installed_leaves") <(echo "$brewfile_formulae"))

# Brewfile entries not installed at all (check against all installed, not just leaves,
# because a Brewfile entry like ripgrep may also be a dependency of something else)
while IFS= read -r pkg; do
  [[ -z "$pkg" ]] && continue
  drift "formula '$pkg' in Brewfile but not installed"
done < <(comm -23 <(echo "$brewfile_formulae") <(echo "$installed_all_formulae"))

if [[ ${#DRIFT[@]} -eq $formulae_drift_count ]]; then
  ok "formulae match Brewfile"
fi

# --- Brew casks ---
section "Brew casks"
brewfile_casks=$(grep '^cask ' "$BREWFILE" | sed 's/^cask "\(.*\)"/\1/' | sort)
installed_casks=$(brew list --cask 2>/dev/null | sort)
cask_drift_count=${#DRIFT[@]}

while IFS= read -r pkg; do
  [[ -z "$pkg" ]] && continue
  drift "cask '$pkg' installed but not in Brewfile"
done < <(comm -23 <(echo "$installed_casks") <(echo "$brewfile_casks"))

while IFS= read -r pkg; do
  [[ -z "$pkg" ]] && continue
  drift "cask '$pkg' in Brewfile but not installed"
done < <(comm -13 <(echo "$installed_casks") <(echo "$brewfile_casks"))

if [[ ${#DRIFT[@]} -eq $cask_drift_count ]]; then
  ok "casks match Brewfile"
fi

# --- /Applications ---
section "Applications"

# Apps expected to exist: brew casks + manual prerequisites + system apps
# Manually-installed apps that are known and intentional:
known_manual_apps=(
  "1Password.app"
  "Amphetamine.app"
  "Google Docs.app"
  "Google Drive.app"
  "Google Sheets.app"
  "Google Slides.app"
  "Conductor.app"
  "GitHub Desktop.app"
  "Pixelmator Pro.app"
  "PyCharm.app"
  "Safari.app"
  "Utilities"
)

# Apps installed by brew casks:
known_cask_apps=(
  "calibre.app"
  "ChatGPT.app"
  "Claude.app"
  "CleanShot X.app"
  "Codex.app"
"Ghostty.app"
  "Google Chrome.app"
  "Rectangle.app"
  "Slack.app"
  "Transmission.app"
  "Visual Studio Code.app"
  "VLC.app"
  "Wispr Flow.app"
)

all_known=("${known_manual_apps[@]}" "${known_cask_apps[@]}")

while IFS= read -r app; do
  [[ -z "$app" ]] && continue
  found=false
  for known in "${all_known[@]}"; do
    if [[ "$app" == "$known" ]]; then
      found=true
      break
    fi
  done
  if ! $found; then
    drift "/Applications/$app not tracked (add to Brewfile or known_manual_apps)"
  fi
done < <(ls /Applications/ 2>/dev/null)

# --- VS Code extensions ---
section "VS Code extensions"
if command -v code &>/dev/null; then
  brewfile_exts=$(grep '^vscode ' "$BREWFILE" | sed 's/^vscode "\(.*\)"/\1/' | tr '[:upper:]' '[:lower:]' | sort)
  installed_exts=$(code --list-extensions 2>/dev/null | tr '[:upper:]' '[:lower:]' | sort)
  ext_drift_count=${#DRIFT[@]}

  while IFS= read -r ext; do
    [[ -z "$ext" ]] && continue
    drift "VS Code extension '$ext' installed but not in Brewfile"
  done < <(comm -23 <(echo "$installed_exts") <(echo "$brewfile_exts"))

  while IFS= read -r ext; do
    [[ -z "$ext" ]] && continue
    drift "VS Code extension '$ext' in Brewfile but not installed"
  done < <(comm -13 <(echo "$installed_exts") <(echo "$brewfile_exts"))

  if [[ ${#DRIFT[@]} -eq $ext_drift_count ]]; then
    ok "VS Code extensions match Brewfile"
  fi
else
  ok "VS Code not installed (skipping extension check)"
fi

# --- Symlinks ---
section "Symlinks"

check_link() {
  local dest="$1" expected_src="$2"
  if [[ ! -L "$dest" ]]; then
    drift "$dest is not a symlink"
  elif [[ "$(readlink "$dest")" != "$expected_src" ]]; then
    drift "$dest points to $(readlink "$dest"), expected $expected_src"
  fi
}

check_link "${HOME}/.zshrc"                                                    "${DOTFILES}/.zshrc"
check_link "${HOME}/.tmux.conf"                                                "${DOTFILES}/.tmux.conf"
check_link "${HOME}/.gitconfig"                                                "${DOTFILES}/.gitconfig"
check_link "${HOME}/.gitignore_global"                                         "${DOTFILES}/.gitignore_global"
check_link "${HOME}/.ssh/config"                                               "${DOTFILES}/.ssh-config"
check_link "${HOME}/.ssh/config.local"                                         "${PRIVATE}/ssh-config.local"
check_link "${HOME}/.config/ghostty/config"                                    "${DOTFILES}/.config/ghostty/config"
check_link "${HOME}/.config/nvim/init.lua"                                     "${DOTFILES}/.config/nvim/init.lua"
check_link "${HOME}/.config/nvim/lazy-lock.json"                               "${DOTFILES}/.config/nvim/lazy-lock.json"
check_link "${HOME}/.config/starship.toml"                                     "${DOTFILES}/.config/starship.toml"
check_link "${HOME}/.config/atuin/config.toml"                                 "${DOTFILES}/.config/atuin/config.toml"
check_link "${HOME}/.config/btop/btop.conf"                                    "${DOTFILES}/.config/btop/btop.conf"
check_link "${HOME}/.config/gh/config.yml"                                     "${DOTFILES}/.config/gh/config.yml"
check_link "${HOME}/.config/git/ignore"                                        "${DOTFILES}/.config/git/ignore"
check_link "${HOME}/.config/fd/config"                                         "${DOTFILES}/.config/fd/config"
check_link "${HOME}/.claude/CLAUDE.md"                                         "${DOTFILES}/.claude/CLAUDE.md"
check_link "${HOME}/.claude/statusline-command.sh"                             "${DOTFILES}/.claude/statusline-command.sh"
check_link "${HOME}/Library/Application Support/Code/User/settings.json"       "${DOTFILES}/vscode-settings.json"
check_link "${HOME}/Library/Application Support/Code/User/keybindings.json"    "${DOTFILES}/vscode-keybindings.json"
check_link "${HOME}/.codex/config.toml"                                        "${DOTFILES}/.codex/config.toml"
check_link "${HOME}/.config/dagu/dags"                                         "${HOME}/github/system/dagu"

symlink_drifts=$(printf '%s\n' "${DRIFT[@]+"${DRIFT[@]}"}" | grep -c "symlink\|points to" 2>/dev/null || true)
if [[ "$symlink_drifts" -eq 0 ]]; then
  ok "all symlinks intact"
fi

# --- File associations ---
section "File associations"
if command -v duti &>/dev/null; then
  assoc_file="${HOME}/github/system/scripts/file-associations.conf"
  assoc_drift_count=${#DRIFT[@]}
  while IFS=' ' read -r ext expected_bundle; do
    [[ -z "$ext" || "$ext" == \#* ]] && continue
    actual_bundle=$(duti -x "${ext#.}" 2>/dev/null | tail -1)
    if [[ "$actual_bundle" != "$expected_bundle" ]]; then
      drift "extension '$ext' handled by '$actual_bundle', expected '$expected_bundle'"
    fi
  done < "$assoc_file"
  if [[ ${#DRIFT[@]} -eq $assoc_drift_count ]]; then
    ok "file associations match"
  fi
else
  ok "duti not installed (skipping file association check)"
fi

# --- New config directories ---
section "New config directories"
known_config_dirs=(
  ghostty nvim starship.toml atuin btop gh git fd dagu  # managed in dotfiles
  configstore yarn op                              # ephemeral / not worth managing
)

config_drift_count=${#DRIFT[@]}
while IFS= read -r dir; do
  [[ -z "$dir" ]] && continue
  dirname=$(basename "$dir")
  found=false
  for known in "${known_config_dirs[@]}"; do
    if [[ "$dirname" == "$known" ]]; then
      found=true
      break
    fi
  done
  if ! $found; then
    drift "~/.config/$dirname exists but isn't managed (new tool config?)"
  fi
done < <(find "${HOME}/.config" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

if [[ ${#DRIFT[@]} -eq $config_drift_count ]]; then
  ok "no new config directories"
fi

# --- Summary ---
echo ""
echo "=============================="
NOTIFY=${1:-}
NOTIFY_EMAIL="the configured Gmail account"

send_email() {
  local subject="$1" body="$2"
  if command -v gog &>/dev/null; then
    gog gmail send --to "$NOTIFY_EMAIL" --subject "$subject" --body="$body" --force 2>/dev/null || true
  fi
}

create_issue() {
  local title="$1" body="$2"
  if command -v gh &>/dev/null; then
    gh issue create --repo patforna/system --title "$title" --body "$body" --label "drift" 2>/dev/null || true
  fi
}

should_notify() {
  [[ -z "${TERM:-}" ]] || [[ "$NOTIFY" == "--notify" ]]
}

if [[ ${#DRIFT[@]} -eq 0 ]]; then
  echo "No drift detected."
  if should_notify; then
    send_email "Drift Check: all clear" "No drift detected."
  fi
  exit 0
else
  echo "${#DRIFT[@]} issue(s) found:"
  body=""
  for d in "${DRIFT[@]}"; do
    echo "  - $d"
    body+="- $d"$'\n'
  done
  if should_notify; then
    create_issue "Drift Check: ${#DRIFT[@]} issue(s)" "$body"
  fi
  exit 0
fi
