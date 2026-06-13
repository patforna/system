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

Installs Homebrew, all packages from the Brewfile (formulae, casks, VS Code extensions, uv tools, Mac App Store apps), Claude Code, msgvault. Verifies git-crypt is unlocked (prompts manual step otherwise), symlinks dotfiles, writes Claude Code settings, configures macOS defaults, sets up login items, and reminds you to start Dagu.

## What's managed

| Category       | Config                                                |
|----------------|-------------------------------------------------------|
| Shell          | [`.zshrc`](dotfiles/.zshrc), [`.tmux.conf`](dotfiles/.tmux.conf) |
| Git            | [`.gitconfig`](dotfiles/.gitconfig), [`.config/git/ignore`](dotfiles/.config/git/ignore) |
| SSH            | [`.ssh-config`](dotfiles/.ssh-config) (uses `Include` for machine-local IP) |
| Terminal       | [`.config/ghostty/config`](dotfiles/.config/ghostty/config) |
| Text expander  | [`.config/espanso/`](dotfiles/.config/espanso/) |
| Neovim         | [`.config/nvim/init.lua`](dotfiles/.config/nvim/init.lua), [`lazy-lock.json`](dotfiles/.config/nvim/lazy-lock.json) |
| Editors        | [`vscode-settings.json`](dotfiles/vscode-settings.json), [`vscode-keybindings.json`](dotfiles/vscode-keybindings.json) |
| Prompt         | [`.config/starship.toml`](dotfiles/.config/starship.toml) |
| History        | [`.config/atuin/config.toml`](dotfiles/.config/atuin/config.toml) |
| Monitor        | [`.config/btop/btop.conf`](dotfiles/.config/btop/btop.conf) |
| GitHub CLI     | [`.config/gh/config.yml`](dotfiles/.config/gh/config.yml) |
| Lazygit        | [`.config/lazygit/config.yml`](dotfiles/.config/lazygit/config.yml) |
| fd             | [`.config/fd/config`](dotfiles/.config/fd/config) |
| gcloud         | [`.config/gcloud/configurations/config_default`](dotfiles/.config/gcloud/configurations/config_default) |
| Claude Code    | [`CLAUDE.md`](private/claude/CLAUDE.md), [`memory/MEMORY.md`](private/claude/memory/MEMORY.md), [`skills/`](dotfiles/.claude/skills/), [`statusline-command.sh`](dotfiles/.claude/statusline-command.sh) |
| Packages       | [`Brewfile`](Brewfile) — formulae, casks, VS Code extensions, uv tools, Mac App Store apps |
| File assocs    | [`scripts/file-associations.conf`](scripts/file-associations.conf) |
| Dagu           | [`dagu/`](dagu/) — see [Dagu workflows](#dagu-workflows) below |

Only config files are symlinked — never caches, auth tokens, or session data.

### Claude Code statusline

Custom statusline rendered by [`statusline-command.sh`](dotfiles/.claude/statusline-command.sh):

> 📁 ~/github/system | 🤖 Opus 4.7 (1M) | 🧠 ▓▓░░░░░░░░ 15% | 🔥 ▓▓▓▓░░░░░░ 42% Resets in 2h 15m

| Section | Source | Description |
|---------|--------|-------------|
| 📁 cwd | stdin JSON | Working directory |
| 🤖 model | stdin JSON | Active model name |
| 🧠 context | stdin JSON | Context window usage — bar turns yellow at 60%, red at 80% |
| 🔥 usage | [OAuth API](https://api.anthropic.com/api/oauth/usage) | 5h billing window — real utilization % + reset countdown |

Usage data is fetched from Anthropic's OAuth endpoint using Claude Code's own credentials (macOS Keychain), cached for 60s, and refreshed in the background to keep render time under 200ms.

## Utilities

`scripts/` ships a few handy CLIs on `$PATH`:

| Command | Purpose |
|---------|---------|
| `find-session <hash\|text>` | Locate a Claude Code session by commit hash or by text — mode auto-detected (hex that resolves to a commit ⇒ hash mode, else text). Hash mode matches the `[branch hash]` signature `git commit` prints, falling back to timestamp-sorted hash mentions when it wasn't captured (e.g. subagent/headless commits). Text mode lists sessions whose transcript matches, newest first; `--prompts-only` restricts to your messages. Pass `--repo` to narrow to the current repo's sessions. |
| `claude-replay`       | Extract a Claude Code session transcript into readable markdown — full subagent prompts/responses, main-thread text, and Bash calls, no TUI truncation. UUIDs resolve globally, so `claude-replay <uuid>` works from any directory; with no arg, falls back to the latest session in the cwd's project. Use `--list` to browse, `--commit <hash>` to locate a session via `find-session`. |
| `drift-check`         | Detect untracked system state and Mac ↔ Linux config divergence. Two surfaces: `--local` (Brewfile, casks, apps, symlinks…) runs weekly via Dagu as an informational nudge; `--remote` (Mac dotfiles vs `remote/`) runs as a gate in `dev-up`/`bootstrap.sh`. No mode = both. `--notify` emails the list and exits 0 (no autofix) — and only when the drift set changed since the last notification; otherwise exits 1 on drift. |
| `dev-up` / `dev-down` | Bring the remote dev droplet up/down and sync local SSH config. |

## Dagu workflows

Local [Dagu](https://dagu.cloud/) instance runs the schedules in [`dagu/`](dagu/). The Mac launchd job starts Dagu on login; the UI is at <http://localhost:8080>.

| DAG                     | Cadence              | What it does                                                                                          |
|-------------------------|----------------------|-------------------------------------------------------------------------------------------------------|
| `msgvault-sync`         | Daily at 03:00       | `msgvault sync` of the personal Gmail account                                                         |
| `drift-check`           | Monday at 03:00      | [`scripts/drift-check`](scripts/drift-check) `--local --notify` — emails local drift, exits 0 (no autofix). Remote parity is gated in `dev-up`, not here. |
| `droplet-watchdog`      | Every 4 hours        | Emails + macOS-notifies if the `dev` DigitalOcean droplet has been up >24h                            |
| `workflow-digest`       | Daily at 04:00       | [`dagu-digest.sh`](scripts/dagu-digest.sh) — summarises 24h (7d for weekly DAGs) status, mails it     |
| `jobs-digest`           | Saturday at 03:00    | Vets last 7d of `label:jobs` mail via `claude -p` against target-role criteria; HTML email            |
| `tech-news-digest`      | Saturday at 03:10    | Ranks last 7d of `label:tech-news` mail via `claude -p` into a single HTML email (03:10, off the 03:00 Gmail spike) |
| `tad-pipeline`          | Tue–Sat at 04:30 UTC | Runs `uv run tad pipeline run -v` in the TAD repo                                                     |
| `tad-daily-code-review` | Daily at 03:00       | Sweeps non-`/auto-task` commits on `main`, ships safe Minor/Nit autofixes via auto-merged PR, escalates Critical/Major as a review PR (email fallback) |

Times are local (Europe/Zurich), except `tad-pipeline`, which is pinned to UTC (DST-proof, clear of the flaky ~02:00 UTC nasdaq window).

### Email signals

`NOTIFY_EMAIL` (set in `private/droplet-watchdog.conf`) receives:

| Subject                                                  | When                                      |
|----------------------------------------------------------|-------------------------------------------|
| `[DAGU] Daily digest — <status>`                         | 04:00 daily                               |
| `[DAGU AUTOFIX] <dag> — needs human`                     | On escalation only                        |
| `[DAGU AUTOFIX] <dag> — re-run after fix still failing`  | Autofixed DAG failed again on re-run      |
| `[TAD SWEEP] review PR — <range>`                        | Sweep opened an escalation PR             |
| `[TAD SWEEP] <range> — needs a human`                    | Sweep escalation with no reviewable fix   |
| `[DRIFT] N untracked item(s)`                            | Monday 03:00, only when the set changed   |
| `Dev droplet running for Xd Yh`                          | Droplet up >24h                           |
| `[Jobs digest]` / `[Tech-news digest]`                   | Saturday 03:00 / 03:10                     |

Daily digest `<status>` is one of `all ok` / `all ok (N auto-fixed)` / `N need attention`. Only `need attention` requires action — body rows are marked OK / FIXED / ATTN; read the per-failure `[DAGU AUTOFIX]` mail or the dagu UI.

### Autofix

DAG failures route through [`scripts/dagu-autofix.sh`](scripts/dagu-autofix.sh) (wired in via `handler_on.failure` in [`base.yaml`](dotfiles/.config/dagu/base.yaml)), which hands the failure to a local Claude session. Classification and behaviour live in the prompt; outcomes append to `~/.local/state/dagu-autofix.jsonl` so the daily digest can mark a handled failure `FIXED` instead of `ATTN`.

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
drift-check
```

## Private files (git-crypt)

The `private/` directory is encrypted on GitHub and decrypted locally.

<!-- Do not list files or content here due to their sensitivity -->

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
