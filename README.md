# system

Mac + remote dev environment, fully automated. One script to bootstrap a new Mac, another for an Ubuntu droplet. Drift detection catches anything that goes untracked. Private files are encrypted via git-crypt.

```
dotfiles/              # config files, symlinked into $HOME
private/               # encrypted (git-crypt): Claude skills, SSH config, personal scripts
scripts/               # bootstrap, dotfile linker, drift checker, utilities
dagu/                  # scheduled workflow definitions (drift check, watchdog)
remote/                # Ubuntu droplet setup (separate bootstrap + configs)
Brewfile               # brew packages, casks, VS Code extensions
```

## Stack

**Terminal:** Ghostty, zsh, tmux, starship, neovim

**Tools:** ripgrep, fd, fzf, eza, bat, delta, lazygit, zoxide, atuin, btop

**Editors:** VS Code, neovim for quick edits

**AI:** Claude Code, Codex

**Remote:** Digital Ocean droplet with tmux — keeps Claude Code running when you close your laptop

## Bootstrap

### Mac

```bash
~/github/system/scripts/bootstrap.sh
```

Installs Homebrew, all packages from the Brewfile, Claude Code, unlocks git-crypt, symlinks dotfiles, configures macOS defaults, and starts Dagu for scheduled workflows.

### Remote droplet

See [`remote/README.md`](remote/README.md) for the full playbook.

## What's managed

| Category       | Config                                                |
|----------------|-------------------------------------------------------|
| Shell          | `.zshrc`, `.tmux.conf`                                |
| Git            | `.gitconfig`, `.config/git/ignore`                    |
| SSH            | `.ssh-config` (uses `Include` for machine-local IP)   |
| Terminal       | `.config/ghostty/config`                              |
| Neovim         | `.config/nvim/init.lua`, `lazy-lock.json`             |
| Editors        | `vscode-settings.json`, `vscode-keybindings.json`     |
| Prompt         | `.config/starship.toml`                               |
| History        | `.config/atuin/config.toml`                           |
| Monitor        | `.config/btop/btop.conf`                              |
| GitHub CLI     | `.config/gh/config.yml`                               |
| fd             | `.config/fd/config`                                   |
| Claude Code    | `statusline-command.sh`                               |
| Codex          | `.codex/config.toml`                                  |
| Packages       | `Brewfile`                                            |
| File assocs    | `scripts/file-associations.conf`                      |

Only config files are symlinked — never caches, auth tokens, or session data.

## Private files (git-crypt)

The `private/` directory is encrypted on GitHub and decrypted locally. It contains:

- `claude/CLAUDE.md` — global Claude Code instructions
- `claude/memory/MEMORY.md` — Claude Code auto-memory
- `skills/` — Claude Code skill definitions (gog, trackid, monthly-spending, ibkr-stocks-update, remote-drift)
- `scripts/` — private utility scripts (tid, tldr)
- `ssh-config.local` — droplet IP (written by `dev-up`)
- `droplet-watchdog.conf` — notification email

### Managing encrypted files

```bash
# Check encryption status
git-crypt status

# See which files are encrypted
git-crypt status -e

# Add a new private file: put it in private/, commit, done.
# The .gitattributes rule encrypts everything in private/ automatically.

# Unlock on a new machine (key stored in 1Password as 'system-git-crypt-key')
git-crypt unlock /path/to/key
```

## Maintenance

```bash
# Update Brewfile after installing new tools
brew bundle dump --file=~/github/system/Brewfile --force

# Re-run dotfile symlinks (idempotent)
dot_files.sh

# Check for local drift manually
drift-check.sh

# Check for Mac ↔ Linux config drift (Claude Code skill)
/remote-drift
```

Scheduled workflows run via [Dagu](https://github.com/dagu-org/dagu) (`brew services start dagu`, web UI at `localhost:8080`). DAG definitions live in `dagu/` and are symlinked to `~/.config/dagu/dags`.

| Workflow           | Schedule        | Description                                      |
|--------------------|-----------------|--------------------------------------------------|
| drift-check        | Daily 10:00     | Detects untracked system changes, files GH issues |
| droplet-watchdog   | Every 4 hours   | Alerts if dev droplet runs longer than 24h       |
| msgvault-sync      | Daily 9:00      | Syncs Gmail to local DuckDB for offline search   |

Drift detection checks:

- Brew formulae/casks vs Brewfile
- `/Applications/` vs known apps
- VS Code extensions vs Brewfile
- All dotfile symlinks
- New unmanaged directories in `~/.config/`
- File associations vs `scripts/file-associations.conf`

## License

[MIT](LICENSE)
