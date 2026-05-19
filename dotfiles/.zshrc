# --- Paths ---
export PATH="/opt/homebrew/bin:$PATH" # homebrew
export PATH="$HOME/.local/bin:$PATH" # claude code
export PATH="$HOME/github/system/scripts:$PATH"
export PATH="$HOME/github/system/private/scripts:$PATH" # git-crypt encrypted
export PATH="/opt/homebrew/opt/trash/bin:$PATH" # trash (keg-only)

# --- History ---
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt share_history      # share between shells
setopt hist_ignore_dups   # no dupes
setopt hist_reduce_blanks # trim extra spaces

# --- Completion ---
autoload -Uz compinit && compinit -C
# Case-insensitive completion
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'

# --- Keybindings ---
bindkey -v               # vi mode
bindkey '^A' beginning-of-line   # Ctrl-A: jump to line start
bindkey '^E' end-of-line         # Ctrl-E: jump to line end

# --- Usability ---
setopt autocd            # `cd dir` → just `dir`
setopt correct            # spellcheck commands
setopt interactive_comments
setopt no_beep
setopt auto_pushd pushd_ignore_dups

# --- Prompt ---
eval "$(starship init zsh)"

# --- Tools ---
eval "$(zoxide init zsh)"

# fzf must be sourced BEFORE atuin so atuin's Ctrl-R binding wins.
export FZF_DEFAULT_COMMAND='rg --files --hidden --follow -g "!.git"'
export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
source <(fzf --zsh)

eval "$(atuin init zsh --disable-up-arrow)"

eval "$(try init ~/experiments)"

# --- Functions ---
c() { pbcopy < "$1"; }
p() { pbpaste > "$1"; }

# --- Aliases ---
# alias cat='bat -pp'
alias pbc=pbcopy
alias pbp=pbpaste
alias cat='bat'
alias l=less
alias rm='trash'              # move to macOS Trash instead of deleting (\rm for real rm)
alias rg='rg --hidden --smart-case'
alias g='rg'
alias grep='rg'
alias vim='nvim'
alias lg='lazygit'
alias md='macdown'

# eza
alias ls="eza --group-directories-first --icons"
alias la="eza -la --group-directories-first --icons"
alias lt='eza --tree --level=2 --group-directories-first --icons --all'
alias lls='eza -l --sort=size --total-size'
alias llm='eza -l --sort=modified'

# zoxide
alias j='z'
alias jj='zi'

# git
alias gco='git checkout'
alias gcb='git switch -c'         # new branch
alias gsw='git switch'            # replace old checkout semantics
alias ga='git add'
alias gaa='git add -A'
alias gc='git commit'
alias gcm='git commit -m'
alias 'gc!'='git commit --amend'
alias gcl='git clone'
alias gd='git diff'
alias gdp='git --no-pager diff'
alias gds='git diff --staged'
alias gsbs='git sbs'             # wide-window side-by-side review: gsbs main...HEAD
alias gpl='git pull --rebase'
alias gp='git push'
alias gpf='git push --force-with-lease'
alias gst='git status -sb'        # short status (better than OMZ version)
alias gss='git status'            # full version

# git: branch helpers
alias gb='git branch'
alias gba='git branch -a'
alias gbd='git branch -d'
alias gbD='git branch -D'
alias gm='git merge'
alias gfr='git fetch --all --prune'

# git: stash
alias gsta='git stash'
alias gstp='git stash pop'
alias gstd='git stash drop'
alias gstl='git stash list'

# git: log
alias gl=glo
alias glo='git log --oneline --graph --decorate'
alias glgp='git log --oneline --graph --decorate --patch'
alias glgs='git log --stat'

# git: varia
alias gundo='git restore .'
alias gwip='git add -A && git commit -m "WIP"'
alias gclean='git reset --hard && git clean -fd'
alias gr='git rebase'
alias gri='git rebase -i'
alias grc='git rebase --continue'
alias gra='git rebase --abort'

# misc
alias n='vim ~/Drive/admin/notes.txt'
alias vz='vim ~/.zshrc'
alias sz='source ~/.zshrc'
alias dev='ssh dev -t "tmux new-session -A -s main"'

# --- tad ---
alias jt='just tasks'
alias jb='just backlog'
alias jc='just check'

# --- Misc ---
export EDITOR="nvim"
export CLAUDE_CODE_MAX_OUTPUT_TOKENS=64000


# GitHub token for Claude Code plugins
export GITHUB_PERSONAL_ACCESS_TOKEN="${GITHUB_PERSONAL_ACCESS_TOKEN:-$(gh auth token)}"

# --- Ghostty shell integration ---
if [ -n "$GHOSTTY_RESOURCES_DIR" ]; then
  # Inside tmux, disable Ghostty's title feature so only Claude Code sets pane titles
  [[ -n "$TMUX" ]] && GHOSTTY_SHELL_FEATURES="${GHOSTTY_SHELL_FEATURES//title/}"
  source "$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/ghostty-integration"
fi

# --- Plugins (must be last) ---
ZSH_AUTOSUGGEST_STRATEGY=(history completion)
source /opt/homebrew/share/zsh-autosuggestions/zsh-autosuggestions.zsh
source /opt/homebrew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

# TAB: fzf-enhanced completion (expands unambiguously, fuzzy picks when multiple matches).
# Bound explicitly because vi mode leaves ^I unbound, which breaks fzf's fallback.
# Autosuggestions are accepted with right-arrow (zsh-autosuggestions default).
bindkey '^I' fzf-completion

