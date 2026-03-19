#!/bin/bash
# Claude Code statusline: cwd, model, context window %, 5h billing window %.
# Reads JSON from stdin. Renders in <200ms (usage refresh is background).

_TMPDIR="${TMPDIR:-/tmp}"
USAGE_CACHE="${_TMPDIR}/claude-usage-cache.json"
USAGE_LOCK="${_TMPDIR}/claude-usage-cache.lock"
USAGE_TTL=60
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# --- Bar renderer ---
render_bar() {
    local pct=$1 width=10
    ((pct < 0)) && pct=0
    ((pct > 100)) && pct=100
    local filled=$((pct * width / 100))
    local empty=$((width - filled))
    local color
    if ((pct >= 80)); then color="\033[31m"
    elif ((pct >= 60)); then color="\033[33m"
    else color="\033[32m"; fi
    local bar=""
    for ((i=0; i<filled; i++)); do bar+="▓"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done
    printf '%b' "${color}${bar} ${pct}%\033[0m"
}

# --- Read stdin & parse in one jq call ---
input=$(cat)
IFS=$'\t' read -r display_name cwd ctx_pct <<< "$(printf '%s' "$input" | jq -r '[
    (.model.display_name // ""),
    (.cwd // ""),
    (.context_window.used_percentage // 0)
] | @tsv')"

# Shorten display name: "(1M context)" -> "(1M)"
display_name="${display_name/ context/}"

# Collapse $HOME to ~
cwd="${cwd/#$HOME/~}"

# --- Section 0: CWD ---
section0=""
[[ -n "$cwd" && "$cwd" != "null" ]] && section0="📁 \033[36m${cwd}\033[0m"

# --- Section 1: Model ---
section1=""
[[ -n "$display_name" && "$display_name" != "null" ]] && section1="\033[32m🤖 ${display_name}\033[0m"

# --- Section 2: Context Window ---
section2=""
((ctx_pct > 0)) && section2="🧠 $(render_bar "$ctx_pct")"

# --- Section 3: 5h Billing Window (via OAuth API, cached) ---
# Uses the same OAuth credentials as Claude Code (macOS Keychain).
# Background-only API calls — never blocks rendering.
refresh_usage() {
    # Break stale lock (>30s old — curl timeout is 5s)
    if [[ -d "$USAGE_LOCK" ]]; then
        local lock_age=$(( $(date +%s) - $(stat -f %m "$USAGE_LOCK" 2>/dev/null || echo 0) ))
        ((lock_age > 30)) && rmdir "$USAGE_LOCK" 2>/dev/null
    fi
    mkdir "$USAGE_LOCK" 2>/dev/null || return 0
    (
        trap 'rmdir "$USAGE_LOCK" 2>/dev/null' EXIT
        # Read token from Keychain, fallback to credentials file
        token=""
        if command -v security &>/dev/null; then
            token=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
                | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
        fi
        [[ -z "$token" && -f "$CLAUDE_DIR/.credentials.json" ]] && \
            token=$(jq -r '.claudeAiOauth.accessToken // empty' "$CLAUDE_DIR/.credentials.json" 2>/dev/null)
        [[ -z "$token" ]] && return 0
        # Fetch usage (process substitution hides token from ps)
        resp=$(curl -sf --max-time 5 \
            -H "Accept: application/json" \
            -H "anthropic-beta: oauth-2025-04-20" \
            -K <(printf 'header = "Authorization: Bearer %s"\n' "$token") \
            "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
        unset token
        [[ -z "$resp" ]] && return 0
        # Validate and write cache atomically
        printf '%s' "$resp" | jq -e '.five_hour' >/dev/null 2>&1 || return 0
        printf '%s' "$resp" | jq '{ts: (now | floor), pct: (.five_hour.utilization // 0 | floor), resets_at: (.five_hour.resets_at // "")}' \
            > "${USAGE_CACHE}.tmp" 2>/dev/null && mv "${USAGE_CACHE}.tmp" "$USAGE_CACHE"
    ) &>/dev/null &
}

section3=""
if [[ -f "$USAGE_CACHE" ]]; then
    IFS=$'\t' read -r cache_ts usage_pct resets_at <<< "$(jq -r '[.ts, .pct, .resets_at] | @tsv' "$USAGE_CACHE" 2>/dev/null)"
    [[ "$cache_ts" =~ ^[0-9]+$ ]] || cache_ts=0
    # Trigger background refresh if stale
    (( $(date +%s) - cache_ts > USAGE_TTL )) && refresh_usage
    if [[ -n "$usage_pct" && "$usage_pct" != "null" ]] && ((usage_pct > 0)); then
        # Compute "Resets in Xh Ym" from resets_at
        reset_text=""
        if [[ -n "$resets_at" && "$resets_at" != "null" ]]; then
            # Strip fractional seconds and timezone suffix for macOS date parsing
            clean_ts="${resets_at%%.*}"
            clean_ts="${clean_ts%%Z}"
            clean_ts="${clean_ts%%+*}"
            reset_epoch=$(TZ=UTC0 date -j -f "%Y-%m-%dT%H:%M:%S" "$clean_ts" +%s 2>/dev/null) || \
                reset_epoch=$(date -u -d "${resets_at}" +%s 2>/dev/null)
            if [[ -n "$reset_epoch" ]]; then
                remaining=$(( reset_epoch - $(date +%s) ))
                if ((remaining <= 0)); then
                    reset_text=" (resetting…)"
                else
                    rh=$((remaining / 3600))
                    rmins=$(( (remaining % 3600) / 60 ))
                    reset_text=" Resets in ${rh}h ${rmins}m"
                fi
            fi
        fi
        section3="🔥 $(render_bar "$usage_pct")${reset_text}"
    fi
else
    refresh_usage
fi

# --- Assemble output ---
output=""
[[ -n "$section0" ]] && output="$section0"
[[ -n "$section1" ]] && output="${output:+$output | }$section1"
[[ -n "$section2" ]] && output="${output:+$output | }$section2"
[[ -n "$section3" ]] && output="${output:+$output | }$section3"
printf '%b' "$output"
