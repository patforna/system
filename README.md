# system

Mac + remote dev environment, fully automated. One script to bootstrap a new Mac, another for an Ubuntu box. Drift detection catches anything that goes untracked. Private files are encrypted via git-crypt.

```
dotfiles/              # config files, symlinked into $HOME
private/               # encrypted (git-crypt): SSH config, personal scripts, etc.
scripts/               # bootstrap, dotfile linker, drift checker, utilities
dagu/                  # scheduled workflow definitions (drift check, watchdog)
remote/                # Ubuntu box setup (separate bootstrap + configs)
Brewfile               # brew packages, casks, VS Code extensions, uv tools, Mac App Store apps
```

## Stack

**Terminal:** Ghostty, zsh, tmux, starship, neovim

**Tools:** ripgrep, fd, fzf, eza, bat, delta, lazygit, zoxide, atuin, btop

**Tracking:** ActivityWatch — local, privacy-first automatic time tracking (localhost:5600)

**Automation:** Dagu — scheduled drift checks, watchdog alerts, syncs

**Editors:** VS Code, neovim for quick edits

**AI:** Claude Code

**Remote:** Digital Ocean box with tmux to keep agents running

## Bootstrap

### Mac

```bash
~/github/system/scripts/bootstrap.sh
```

Installs Homebrew, all packages from the Brewfile (formulae, casks, VS Code extensions, uv tools, Mac App Store apps), Claude Code, unlocks git-crypt, symlinks dotfiles, configures macOS defaults, sets up login items (ActivityWatch, Rectangle), and starts Dagu for scheduled workflows.

## What's managed

| Category       | Config                                                |
|----------------|-------------------------------------------------------|
| Shell          | [`.zshrc`](dotfiles/.zshrc), [`.tmux.conf`](dotfiles/.tmux.conf) |
| Git            | [`.gitconfig`](dotfiles/.gitconfig), [`.config/git/ignore`](dotfiles/.config/git/ignore) |
| SSH            | [`.ssh-config`](dotfiles/.ssh-config) (uses `Include` for machine-local IP) |
| Terminal       | [`.config/ghostty/config`](dotfiles/.config/ghostty/config) |
| Neovim         | [`.config/nvim/init.lua`](dotfiles/.config/nvim/init.lua), [`lazy-lock.json`](dotfiles/.config/nvim/lazy-lock.json) |
| Editors        | [`vscode-settings.json`](dotfiles/vscode-settings.json), [`vscode-keybindings.json`](dotfiles/vscode-keybindings.json) |
| Prompt         | [`.config/starship.toml`](dotfiles/.config/starship.toml) |
| History        | [`.config/atuin/config.toml`](dotfiles/.config/atuin/config.toml) |
| Monitor        | [`.config/btop/btop.conf`](dotfiles/.config/btop/btop.conf) |
| GitHub CLI     | [`.config/gh/config.yml`](dotfiles/.config/gh/config.yml) |
| fd             | [`.config/fd/config`](dotfiles/.config/fd/config) |
| Claude Code    | [`CLAUDE.md`](private/claude/CLAUDE.md), [`memory/MEMORY.md`](private/claude/memory/MEMORY.md), [`statusline-command.sh`](dotfiles/.claude/statusline-command.sh) |
| Packages       | [`Brewfile`](Brewfile) — formulae, casks, VS Code extensions, uv tools, Mac App Store apps |
| File assocs    | [`scripts/file-associations.conf`](scripts/file-associations.conf) |
| Dagu           | [`dagu/`](dagu/) — drift-check, droplet-watchdog, msgvault-sync, workflow-digest |

Only config files are symlinked — never caches, auth tokens, or session data.

### Claude Code statusline

Custom statusline rendered by [`statusline-command.sh`](dotfiles/.claude/statusline-command.sh):

> 📁 ~/github/system | 🤖 Opus 4.6 (1M) | 🧠 ▓▓░░░░░░░░ 15% | 🔥 ▓▓▓▓░░░░░░ 42% Resets in 2h 15m

| Section | Source | Description |
|---------|--------|-------------|
| 📁 cwd | stdin JSON | Working directory |
| 🤖 model | stdin JSON | Active model name |
| 🧠 context | stdin JSON | Context window usage — bar turns yellow at 60%, red at 80% |
| 🔥 usage | [OAuth API](https://api.anthropic.com/api/oauth/usage) | 5h billing window — real utilization % + reset countdown |

Usage data is fetched from Anthropic's OAuth endpoint using Claude Code's own credentials (macOS Keychain), cached for 60s, and refreshed in the background to keep render time under 25ms.

## Utilities

`scripts/` ships a few handy CLIs on `$PATH`:

| Command | Purpose |
|---------|---------|
| `find-session <hash>` | Locate the Claude Code session that made a given git commit. Matches the `[branch hash]` signature `git commit` prints; falls back to timestamp-sorted hash mentions when the signature wasn't captured (e.g. subagent/headless commits). Pass `--repo` to narrow to the current repo's sessions. |
| `drift-check.sh`      | Detect untracked dotfiles, Brewfile drift, and Mac ↔ Linux config divergence. Runs daily via Dagu. |
| `dev-up` / `dev-down` | Bring the remote dev droplet up/down and sync local SSH config. |

## Remote box

See [`remote/README.md`](remote/README.md) for the full playbook.

## Maintenance

```bash
# Update Brewfile after installing new tools
brew bundle dump --file=~/github/system/Brewfile --force

# Add a new tool by type
brew bundle add <formula>                    # brew formula
brew bundle add --cask <app>                 # desktop app
brew bundle add --vscode <extension-id>      # VS Code extension
brew bundle add --uv <package>               # Python CLI tool (via uv)
# Mac App Store: add manually — mas "Name", id: <id> (find id with: mas search <name>)

# Re-run dotfile symlinks (idempotent)
dot_files.sh

# Check for drift manually (includes Mac ↔ Linux remote config drift)
drift-check.sh
```

## Private files (git-crypt)

The `private/` directory is encrypted on GitHub and decrypted locally. It contains:

- `claude/CLAUDE.md` — global Claude Code instructions
- `claude/memory/MEMORY.md` — Claude Code auto-memory
- `skills/` — Claude Code skill definitions (trackid, monthly-spending, ibkr-stocks-update)
- `scripts/` — private utility scripts (tid, tldr)
- `ssh-config.local` — box IP (written by `dev-up`)
- `droplet-watchdog.conf` — notification email

### Managing encrypted files

```bash
# Check encryption status
git-crypt status

# See which files are encrypted
git-crypt status -e

# Add a new private file: put it in private/, commit, done.
# The .gitattributes rule encrypts everything in private/ automatically.

# Unlock on a new machine (key stored in 1Password)
git-crypt unlock /path/to/key
```

## License

[MIT](LICENSE)
