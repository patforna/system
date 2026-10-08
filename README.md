# system

Mac + remote dev environment, fully automated. One script to bootstrap a new Mac, another for an Ubuntu box. Drift detection catches anything that goes untracked. Private files are encrypted via git-crypt.

[![CI](https://github.com/patforna/system/actions/workflows/ci.yml/badge.svg)](https://github.com/patforna/system/actions/workflows/ci.yml)

```
dotfiles/              # config files, symlinked into $HOME
private/               # encrypted (git-crypt): SSH config, personal scripts, etc.
scripts/               # bootstrap, dotfile linker, drift checker, utilities
dagu/                  # workflow definitions (executed by the reconciler, not cron)
remote/                # Ubuntu box setup (separate bootstrap + configs)
Brewfile               # brew packages, casks, VS Code extensions, uv tools, Mac App Store apps
```

## Stack

**Terminal:** Ghostty, zsh, tmux, starship, neovim

**Tools:** ripgrep, fd, fzf, eza, bat, delta, lazygit, zoxide, atuin, btop

**Automation:** Dagu (executor) + a level-triggered reconciler — drift checks, backups, watchdog, digests

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
| `find-session <hash\|text>` | Locate a Claude Code session by commit hash or by text — mode auto-detected (hex that resolves to a commit ⇒ hash mode, else text). Hash mode matches the `[branch hash]` signature `git commit` prints, falling back to timestamp-sorted hash mentions when it wasn't captured (e.g. subagent/headless commits). Text mode searches what *you* typed — injected records, slash-command wrappers and `<system-reminder>` blocks don't count as prompts — and lists only sessions you can resume: subagent transcripts and headless/cron runs (no `{"type":"mode"}` record) need `--include-agents` / `--include-headless`. Each hit prints the matching prompt and a copy-pasteable `cd <dir> && claude --dangerously-skip-permissions --resume <id>`, the dir taken from the session's recorded `cwd`. `--all-text` widens to the whole transcript, `--repo` narrows to the current repo, `--limit N` caps output (default 10), `--safe` drops the yolo flag. |
| `claude-replay`       | Extract a Claude Code session transcript into readable markdown — full subagent prompts/responses, main-thread text, and Bash calls, no TUI truncation. UUIDs resolve globally, so `claude-replay <uuid>` works from any directory; with no arg, falls back to the latest session in the cwd's project. Use `--list` to browse, `--commit <hash>` to locate a session via `find-session`. |
| `drift-check`         | Detect untracked system state and Mac ↔ Linux config divergence. Two surfaces: `--local` (Brewfile, casks, apps, symlinks…) runs roughly weekly via the reconciler as an informational nudge; `--remote` (Mac dotfiles vs `remote/`) runs as a gate in `dev-up`/`bootstrap.sh`. No mode = both. `--notify` emails the list and exits 0 (no autofix) — and only when the drift set changed since the last notification; otherwise exits 1 on drift. |
| `dev-up` / `dev-down` | Bring the remote dev droplet up/down and sync local SSH config. |

## Dagu workflows

Local [Dagu](https://dagu.cloud/) instance runs the jobs in [`dagu/`](dagu/) — as an executor, not a scheduler. The Mac launchd job starts Dagu on login; the UI is at <http://localhost:8080>.

**Scheduling is level-triggered, not cron.** This is a laptop that sleeps through every night (and travels), so a fixed cron time is the wrong model — the edge lands while the machine is asleep and the run is lost. Instead, [`scripts/dagu-reconcile`](scripts/dagu-reconcile) runs every 5 minutes via launchd and asks *"what is overdue?"*, starting only the jobs whose freshness SLO has lapsed, and only when the Mac is awake **and** online. State (a per-job last-success marker) survives sleep; cron edges don't. Being off is simply a pause — nothing is "missed", it just runs when the machine is next available. Rationale and the failure modes this replaced are in [`private/GOTCHAS.md`](private/GOTCHAS.md).

- **Freshness SLOs** live in [`scripts/dagu-jobs.conf`](scripts/dagu-jobs.conf) — one line per job, in the order they run (serially).
- **Lanes.** A pass is serial, so a job waits behind every long job ahead of it. A job that must not wait gets a lane (third column in `dagu-jobs.conf`) and its own launchd agent running `dagu-reconcile <lane>` concurrently with the main pass. `coach-inbox` and `plant-inbox` share one (`fast`, agent `com.patric.dagu-reconcile-fast`), coach first; the backups must stay in the main lane (restic's repo lock).
- **Success markers** (`~/.local/state/dagu-success/<dag>`) are written by dagu's own `handler_on.success` and are the reconciler's source of truth for "last succeeded" — not dagu's status store.
- **No in-process retries or network waits.** A job that fails or can't run stays overdue and is retried at the next tick; a job must never sleep across a suspend.

| DAG                     | SLO (max staleness) | What it does                                                                                          |
|-------------------------|---------------------|-------------------------------------------------------------------------------------------------------|
| `msgvault-sync`         | 20h                 | `msgvault sync` of the personal Gmail account                                                         |
| `coach-inbox`           | 4m                  | Fast lane, first. [`coach-inbox.sh`](scripts/coach-inbox.sh) — if a rehearsal take on the Story Coach recorder (`~/github/story-coach/recorder`) waits for its read, one schema-bound `run_claude_json` call per take (no tools; read v3 by default: a context step, a Haiku pre-pass, then a lean call with its own system prompt; `READ_VERSION=v2` for the old read), the gate, and the read posted back; a read that misses the gate twice marks the take failed and exits 0 (autofix is for transport only). Otherwise one HTTP call and done |
| `plant-inbox`           | 4m (1h normally)    | Fast lane. [`plant-inbox.sh`](scripts/plant-inbox.sh) — if the garden app ([`plant-selection`](../plant-selection)) has anything waiting for Claude, runs its `inbox` skill headless (answers questions, writes up plant ideas, deploys); otherwise one HTTP call and done |
| `tad-pipeline`          | 20h                 | `uv run tad pipeline run -v` in the TAD repo (loaders resume from last date, so gaps backfill)        |
| `tad-backup-data`       | 20h                 | restic → B2 backup of `~/github/tad/data`; runs right after the pipeline, so it captures fresh output |
| `tad-backup-edgar`      | ~6.5d               | restic → B2 backup of `~/.cache/tad/edgar` (~28GB); serial-adjacent to the data backup (shared repo lock) |
| `drift-check`           | ~6.5d               | [`scripts/drift-check`](scripts/drift-check) `--local --notify` — emails local drift, exits 0 (no autofix). Remote parity is gated in `dev-up`, not here. |
| `tad-daily-code-review` | 20h                 | Sweeps non-`/auto-task` commits on `main`, ships safe Minor/Nit autofixes via auto-merged PR, escalates Critical/Major as a review PR (email fallback) |
| `droplet-watchdog`      | 4h                  | Emails + macOS-notifies if the `dev` DigitalOcean droplet has been up >24h. NB: can't run while the Mac is off — the one job that would benefit from an always-on host. |
| `jobs-digest`           | 78h                 | Vets recent `label:jobs` mail via `claude -p` against target-role criteria; HTML email                |
| `tech-news-digest`      | ~6.5d               | Extracts stories from recent `label:tech-news` mail via chunked `claude -p` calls, one ranking call, HTML rendered in-script |
| `workflow-digest`       | 20h                 | [`dagu-digest.sh`](scripts/dagu-digest.sh) — reports each job's freshness vs SLO; runs last so it reflects this pass |

There are **no cron schedules and no fixed times**. Weekly-ish jobs (SLO ~6.5d) may land on any weekday; they summarise a trailing window, so the day carries no meaning.

### Email signals

`NOTIFY_EMAIL` (set in `private/droplet-watchdog.conf`) receives:

| Subject                                                  | When                                      |
|----------------------------------------------------------|-------------------------------------------|
| `[DAGU] Daily digest — <status>`                         | Once a day (whenever the digest job runs) |
| `[DAGU AUTOFIX] <dag> — needs human`                     | On escalation only                        |
| `[DAGU AUTOFIX] <dag> — re-run after fix still failing`  | Autofixed DAG failed again on re-run      |
| `[TAD SWEEP] review PR — <range>`                        | Sweep opened an escalation PR             |
| `[TAD SWEEP] <range> — needs a human`                    | Sweep escalation with no reviewable fix   |
| `[DRIFT] N untracked item(s)`                            | On drift-check, only when the set changed |
| `Dev droplet running for Xd Yh`                          | Droplet up >24h                           |
| `[Jobs digest]`                                          | Roughly twice weekly                      |
| `[Tech-news digest]`                                     | Roughly weekly                            |

Daily digest `<status>` is `all ok`, optionally with a suffix like `(2 idle by design)` or `(1 drift pending)`, or `N need attention`. Each row carries a marker:

- **OK** — succeeded within its SLO.
- **DRIFT** — untracked system state waiting on a decision (not a failure).
- **IDLE** — stale, but the Mac was off/offline since the job fell due — expected, no action. This is what keeps a holiday quiet: absence-without-opportunity never alarms.
- **ATTN** — stale *despite* the Mac being awake and online — the only marker that needs you.

### Autofix

DAG failures route through [`scripts/dagu-autofix.sh`](scripts/dagu-autofix.sh) (wired in via `handler_on.failure` in [`base.yaml`](dotfiles/.config/dagu/base.yaml)), which hands the failure to a local Claude session. Classification and behaviour live in the prompt; outcomes append to `~/.local/state/dagu-autofix.jsonl` so the daily digest can mark a handled failure `FIXED` instead of `ATTN`.

## WhatsApp (MCP)

Claude reads WhatsApp through [verygoodplugins/whatsapp-mcp](https://github.com/verygoodplugins/whatsapp-mcp) (a maintained fork — the popular `lharries` original has been unmerged since April 2025), cloned at `~/github/whatsapp-mcp`. A Go bridge links as a WhatsApp **companion device** via `whatsmeow` and mirrors messages into local SQLite; a Python MCP server reads that DB and is registered in Claude Code user scope as `whatsapp`.

| Piece      | Where                                                                 |
|------------|-----------------------------------------------------------------------|
| Config     | `~/github/whatsapp-mcp/.env` — **not auto-loaded**; launchers source it explicitly |
| Bridge     | `com.whatsapp-mcp.bridge` + `.bridge-monitor` LaunchAgents, port **8099** (8080 is dagu) |
| Data       | `~/github/whatsapp-mcp/whatsapp-bridge/store/` — messages, session, REST token |
| Logs       | `~/Library/Logs/whatsapp-mcp/`                                        |
| Reinstall  | `set -a; source .env; set +a; scripts/install-launchd-macos.sh`        |

**Read-only by deny rule.** The five write tools (`send_message`, `send_reaction`, `send_file`, `send_audio_message`, `mark_messages_read`) are listed under `permissions.deny` in `~/.claude/settings.json`, which removes them from Claude's context entirely rather than prompting — so it holds under `--dangerously-skip-permissions` too. Claude drafts replies; sending stays manual. Delete those five lines to enable sending.

That file is deliberately **not** tracked here and not compared by `drift-check` — see *drift-check Claude settings…* in [`GOTCHAS`](private/GOTCHAS.md), where mirroring it was tried four times and abandoned. So the deny rules are local-only state: nothing will flag their absence, and a re-provisioned machine comes back **send-enabled**. Re-add them by hand after any `~/.claude` reset.

Two standing caveats: linking a personal number via the reverse-engineered protocol breaches WhatsApp's ToS and carries a small but real ban risk (Meta warned/banned `whatsmeow` users in May 2025, including low-volume reply-only accounts); and any MCP with access to private messages is exposed to the [lethal trifecta](https://simonwillison.net/2025/Jun/16/the-lethal-trifecta/) — incoming messages are untrusted text. The deny rules close the WhatsApp-native exfiltration path.

Re-pairing (QR rescan) is needed if the phone is offline >14 days, the device is unlinked, or WhatsApp revokes the session. The bridge only prints its **first** QR and each code is valid ~60s, so on a stale code restart the bridge rather than waiting out its 5-minute retry.

## Web apps (patforna.com)

Small web apps shared by link (family, garden people, Patric's own tools) each run on their own DigitalOcean droplet, Bun behind Caddy, and get a subdomain of `patforna.com`.

| Subdomain             | Repo                         | Droplet           |
|-----------------------|------------------------------|-------------------|
| `rocks.patforna.com`  | `~/github/rock-selection`    | `rock-selection`  |
| `plants.patforna.com` | `~/github/plant-selection`   | `plant-selection` |
| `coach.patforna.com`  | `~/github/story-coach`       | `story-coach`     |
| `[www.]patforna.com`  | `patforna/patforna.com`      | GitHub Pages      |

- **Domain**: registered at Porkbun (Patric's account, auto-renew on). Its nameservers point at DigitalOcean, so the zone is managed with `doctl compute domain records list patforna.com`. Porkbun is only touched for renewals.
- **Porkbun's copy is temporary.** Porkbun keeps an authoritative zone for every domain it registers, even one delegated elsewhere, and resolvers that cached the old Porkbun delegation (the `.com` referral lives 48 h) kept asking it after the switch on 7 Oct 2026. So Porkbun's zone holds a copy of the A records (`rocks`, `plants`, `coach`, apex), the `www` CNAME and nothing else, until those caches expire, expected by 9 Oct 2026 ~14:05 UTC. Then check `dig +short TXT ghost-canary.patforna.com @1.1.1.1` (and `@1.0.0.1`, a few times each): `digitalocean` everywhere means delete the Porkbun copies and both canary records. Porkbun API key: `~/.config/porkbun/env`; `POST /api/json/v3/dns/retrieve/patforna.com` lists, `dns/delete/patforna.com/<id>` deletes.
- **Each app's `deploy-do.sh` owns its record.** `DOMAIN=<sub>.patforna.com` at the top of the script; `up` points the A record at the droplet (TTL 300) and writes a Caddy block for the name, which gets its Let's Encrypt certificate on its own; `link` prints `https://<sub>.patforna.com/?key=…`; `down` deletes the record, so a released IP can't serve the name.
- **The bare domain** forwards to LinkedIn: a GitHub Pages site (repo `patforna/patforna.com`, one `index.html` with a meta refresh). DNS: apex A/AAAA records to GitHub's Pages IPs, `www` a CNAME to `patforna.github.io`.
- **Monitoring**: droplets are created with the DigitalOcean metrics agent (`--enable-monitoring`) and the `web-app` tag. Three alert policies on that tag email Patric: memory above 90% for 10 min, disk above 80%, CPU above 90% for 30 min (`doctl monitoring alert list`). Graphs are in the control panel, per droplet.
- **Adding an app**: copy one of the scripts above, set `NAME`, `APP` and `DOMAIN`, keep the `web-app` tag, run `up`. No DNS console, no Porkbun. Add a row to the table.
- **Subdomains, not paths** (`patforna.com/rocks`): apps stay independent (own droplet, own origin, so no shared cookies or localStorage) and need no base-path awareness.
- **Old addresses**: the Caddyfiles still serve each droplet's bare IP or `<ip>.sslip.io`, because links shared before October 2026 use them. Drop those blocks once nobody does.
- **The key cookie is per hostname**: a device that used the old address needs the new link (with `?key=`) once.
- **Corporate web filters** (e.g. Fortinet) can block newly registered domains for about 30 days, and block sslip.io outright. The bare IP gets through.

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
