#!/usr/bin/env bash
set -uo pipefail  # no -e: collect all drift items rather than stopping on first failure

# Drift check: detect anything installed/changed on the system that isn't
# tracked in the Brewfile, dotfiles, or README.
#
# Always exits 0 (Dagu treats non-zero as failure).
# When run via Dagu (or with --notify), sends an email summary.

export PATH="${HOME}/.local/bin:${PATH}"

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

# Manual apps loaded from external file (one app per line, # comments ignored)
MANUAL_APPS_FILE="${HOME}/github/system/scripts/manual-apps.conf"
all_known=()
while IFS= read -r line; do
  [[ -z "$line" || "$line" == \#* ]] && continue
  all_known+=("$line")
done < "$MANUAL_APPS_FILE"

# Add apps installed by brew casks (detected from Caskroom)
while IFS= read -r app; do
  [[ -z "$app" ]] && continue
  all_known+=("$app")
done < <(find "$(brew --prefix)/Caskroom" -name '*.app' -maxdepth 3 -exec basename {} \; 2>/dev/null)

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
    drift "/Applications/$app not tracked (add to Brewfile or manual-apps.conf)"
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
check_link "${HOME}/.claude/CLAUDE.md"                                         "${PRIVATE}/CLAUDE.md"
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

# --- Standalone binaries (not managed by Homebrew) ---
section "Standalone binaries"
standalone_bins=(claude msgvault)
bin_drift_count=${#DRIFT[@]}

for bin in "${standalone_bins[@]}"; do
  if ! command -v "$bin" &>/dev/null; then
    drift "'$bin' not installed (expected in PATH)"
  fi
done

if [[ ${#DRIFT[@]} -eq $bin_drift_count ]]; then
  ok "all standalone binaries present"
fi

# --- New config directories ---
section "New config directories"
# Config dirs managed in dotfiles (detected automatically)
known_config_dirs=()
while IFS= read -r dir; do
  known_config_dirs+=("$(basename "$dir")")
done < <(find "${DOTFILES}/.config" -mindepth 1 -maxdepth 1 2>/dev/null)

# Additional unmanaged but expected config dirs
UNMANAGED_CONFIG_FILE="${HOME}/github/system/scripts/unmanaged-config-dirs.conf"
while IFS= read -r line; do
  [[ -z "$line" || "$line" == \#* ]] && continue
  known_config_dirs+=("$line")
done < "$UNMANAGED_CONFIG_FILE"

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
CONF="${HOME}/Drive/system/droplet-watchdog.conf"
[[ -f "$CONF" ]] && source "$CONF"  # expects NOTIFY_EMAIL

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
