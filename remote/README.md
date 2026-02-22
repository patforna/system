# Remote Dev (Digital Ocean Droplet)

Claude Code running in tmux on a DO droplet — keeps running when you close your laptop.

```
remote/
├── bootstrap.sh   # Full setup script for Ubuntu droplet
├── zshrc          # Linux-adapted shell config
├── tmux.conf      # Linux-adapted tmux config
└── gitconfig      # Linux-adapted git config
```

The `dev-up` and `dev-down` scripts for managing the droplet lifecycle live in `scripts/` at the repo root (see [Spin down / up](#spin-down--up)).

## Differences from Mac configs

**zshrc** — No Homebrew paths, no pbcopy/pbpaste. Plugin paths point to `/usr/share/` (Ubuntu apt).

**tmux.conf** — Copy mode uses `copy-selection-and-cancel` instead of piping to `pbcopy` — clipboard syncs via OSC 52.

**gitconfig** — `gh auth git-credential` instead of `osxkeychain`.

## What bootstrap installs

| Method | Tools |
|---|---|
| apt | zsh, tmux, neovim, git, ripgrep, bat, fd, btop, jq, build-essential, zsh-autosuggestions, zsh-syntax-highlighting |
| nodesource apt | Node.js 22 (Claude Code plugins) |
| GitHub apt repo | gh |
| GitHub releases | fzf, delta, lazygit, eza |
| curl installers | just, starship, atuin, zoxide, uv |
| native installer | Claude Code |

## Playbook

### 1. Create the droplet

Ubuntu 24.04, 4GB+ RAM, add your SSH key on creation.

### 2. Set the IP

Write the droplet IP to your local SSH config:

```bash
echo -e "Host dev\n  HostName <DROPLET_IP>" > ~/Drive/system/ssh-config.local
```

The `dev` alias in `dotfiles/.ssh-config` uses `Include config.local` to pick this up.

### 3. First-time server setup (as root)

```bash
ssh root@<DROPLET_IP>
adduser <username> && usermod -aG sudo <username>
cp -r ~/.ssh /home/<username>/.ssh && chown -R <username>:<username> /home/<username>/.ssh
echo '<username> ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers.d/<username>
exit
```

### 4. Bootstrap

From your Mac — install the Ghostty terminfo so the remote knows about your terminal:

```bash
infocmp -x xterm-ghostty | ssh dev 'tic -x -'
```

Then SSH in and clone + bootstrap:

```bash
ssh dev
git clone https://github.com/patforna/system.git ~/github/system
~/github/system/remote/bootstrap.sh
exec zsh
gh auth login
claude login
atuin login && atuin sync
```

### 5. Clone repos

```bash
gh repo clone <org>/<repo> ~/github/<repo>
```

### 6. Connect

```bash
dev
```

### Spin down / up

The droplet bills hourly, so snapshot and destroy it when you're not using it. Two scripts in `scripts/` handle the lifecycle (requires `doctl`: `brew install doctl && doctl auth init`):

**`dev-down`** — Shuts down the droplet, creates a snapshot (`dev-snapshot`), then destroys the droplet. Shows uptime and cost before tearing down.

**`dev-up`** — Restores a new droplet from the snapshot, updates `~/Drive/system/ssh-config.local` with the new IP, deletes the snapshot, and clears the old SSH host key.

```bash
dev-down   # done for the day — snapshot + destroy
dev-up     # back to work — restore from snapshot
```

### Cursor Remote SSH

Connect to `dev` in the Remote Explorer — it picks up your SSH config.

## Drift

The Mac and Linux configs are maintained separately (`dotfiles/` vs `remote/`) because some things can't be shared directly (Homebrew paths, `pbcopy`, osxkeychain, etc.). When you update one side, the other may need a corresponding change.

To check for drift between the two, use the `remote-drift` Claude Code skill:

```
/remote-drift
```

It diffs the Mac dotfiles against their Linux equivalents and flags anything that looks out of sync — e.g. a new alias added to `.zshrc` that's missing from `remote/zshrc`, or a tmux change that needs porting.

Run it any time you make a non-trivial change to a shared config file.
