#!/usr/bin/env bash
set -uo pipefail

# Weekly tech-news digest. Sends an HN-style ranked email to NOTIFY_EMAIL by
# feeding 7 days of label:tech-news mail through claude -p.
# Designed to run via dagu (see dagu/tech-news-digest.yaml).
#
# claude -p renders the HTML to /tmp/tech-news.html; this script then sends.
# Keeping the +send out of the model loop avoids alias / PATH surprises in the
# Bash tool's shell (e.g. zsh `alias cat='bat'` silently emptying --body).

CONF="${HOME}/github/system/private/droplet-watchdog.conf"
[[ -f "$CONF" ]] && source "$CONF"

NOTIFY_EMAIL="${NOTIFY_EMAIL:-}"
[[ -z "$NOTIFY_EMAIL" ]] && { echo "NOTIFY_EMAIL not set" >&2; exit 1; }

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
DATA_FILE="/tmp/tech-news-data.json"
PROMPT_FILE="$SCRIPT_DIR/tech-news/prompt.md"
HTML_FILE="/tmp/tech-news.html"
DATE=$(date '+%Y-%m-%d')

CLAUDE=/Users/patric/.local/bin/claude
PYTHON3=/usr/bin/python3
GWS=/opt/homebrew/bin/gws

# 1. Fetch 7 days of tech-news mail
"$PYTHON3" "$SCRIPT_DIR/tech-news/fetch-data.py" \
    --days 7 --label tech-news --output "$DATA_FILE" || {
  echo "fetch failed" >&2; exit 1;
}

# 2. Render
[[ -f "$PROMPT_FILE" ]] || { echo "missing $PROMPT_FILE" >&2; exit 1; }
rm -f "$HTML_FILE"

prompt=$(sed -e "s|{DATA_FILE}|$DATA_FILE|g" \
             -e "s|{DATE}|$DATE|g" "$PROMPT_FILE")

echo "=== Rendering ==="
"$CLAUDE" -p \
    --permission-mode bypassPermissions \
    --model claude-opus-4-7 \
    "$prompt" 2>&1 | tee /tmp/tech-news.log

if [[ ! -s "$HTML_FILE" ]]; then
  echo "$HTML_FILE missing or empty — skipping send" >&2
  exit 1
fi

# 3. Send
echo "=== Sending ==="
"$GWS" gmail +send \
    --to "$NOTIFY_EMAIL" \
    --subject "[Tech-news digest] Week ending $DATE" \
    --body "$(cat "$HTML_FILE")" \
    --html
