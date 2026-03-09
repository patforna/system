# Short-Term Fixes Proposal

Four targeted changes to reduce brittleness. No new tools, minimal effort.

---

## 1. Delete orphaned launchd plists

The Dagu migration is done but these files still exist in `~/Drive/system/`:

```
com.patric.drift-check.plist
com.patric.droplet-watchdog.plist
```

They aren't loaded (you'd see them in `launchctl list`) but they're confusing —
especially since drift-check.sh still references launchd in its header comment.

**Changes:**
- Delete both plist files from `~/Drive/system/`
- Update comment in `drift-check.sh` line 8: `launchd` → `Dagu`
- Update comment in `droplet-watchdog.sh` line 8: `launchd` → `Dagu`

---

## 2. Externalize known apps lists from drift-check.sh

The `known_manual_apps` and `known_cask_apps` arrays (lines 76–106) are the most
frequent maintenance burden — every new app install means editing the script.

**Changes:**
- Extract both lists to `scripts/known-apps.conf` (one app per line, comments for sections):

```
# Manual installs (App Store, direct download, bundled)
1Password.app
Amphetamine.app
Google Docs.app
Google Drive.app
Google Sheets.app
Google Slides.app
Conductor.app
GitHub Desktop.app
Pixelmator Pro.app
PyCharm.app
Safari.app
Utilities

# Brew cask apps (keep in sync with Brewfile)
calibre.app
ChatGPT.app
Claude.app
CleanShot X.app
Codex.app
Ghostty.app
Google Chrome.app
Rectangle.app
Slack.app
Transmission.app
Visual Studio Code.app
VLC.app
Wispr Flow.app
```

- Update `drift-check.sh` to read from the file instead of hardcoded arrays
- Drift output already tells you what to add — now you just append to a text file
  instead of editing bash arrays

---

## 3. Unify notification pattern in droplet-watchdog.sh

Currently `drift-check.sh` uses `gog gmail send` (clean, works anywhere) while
`droplet-watchdog.sh` uses `osascript` + Mail.app (fragile, macOS-only, opens Mail).

**Changes:**
- Replace the Mail.app `osascript` block (lines 64–74) with `gog gmail send`:

```bash
# --- Send email via gog ---
if command -v gog &>/dev/null; then
  gog gmail send \
    --to "$NOTIFY_EMAIL" \
    --subject "Dev droplet running for ${UPTIME_DAYS}d ${UPTIME_REM}h" \
    --body "Your DigitalOcean dev droplet has been running for ${UPTIME_DAYS} days and ${UPTIME_REM} hours.

Run dev-down to snapshot and destroy it.

— droplet-watchdog" \
    --force 2>/dev/null || true
fi
```

- Keep the macOS notification (`osascript -e "display notification ..."`) — that one
  is fine and useful for immediate visibility

---

## 4. Externalize known config dirs from drift-check.sh

Same pattern as the apps list — `known_config_dirs` (line 223) is another hardcoded
array that needs editing whenever you install a tool that creates a `~/.config/` dir.

**Changes:**
- Extract to `scripts/known-config-dirs.conf` (one dir name per line):

```
# Managed in dotfiles
ghostty
nvim
starship.toml
atuin
btop
gh
git
fd
dagu

# Ephemeral / not worth managing
configstore
yarn
op
```

- Update `drift-check.sh` to read from the file

---

## Summary

| Fix | Files touched | Effort |
|-----|--------------|--------|
| Delete orphaned plists | 2 deleted, 2 comment edits | 5 min |
| Externalize known apps | 1 new conf file, drift-check.sh edit | 15 min |
| Unify notifications | droplet-watchdog.sh edit | 10 min |
| Externalize config dirs | 1 new conf file, drift-check.sh edit | 10 min |

Total: ~40 minutes. No new dependencies. All backward-compatible.
