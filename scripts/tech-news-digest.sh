#!/usr/bin/env bash
set -uo pipefail

# Weekly tech-news digest. Sends Format A (tiered) and Format B (HN-ranked) emails
# to NOTIFY_EMAIL by feeding 7 days of label:tech-news mail through claude -p.
# Designed to run via dagu (see dagu/tech-news-digest.yaml).

CONF="${HOME}/github/system/private/droplet-watchdog.conf"
[[ -f "$CONF" ]] && source "$CONF"

NOTIFY_EMAIL="${NOTIFY_EMAIL:-}"
[[ -z "$NOTIFY_EMAIL" ]] && { echo "NOTIFY_EMAIL not set" >&2; exit 1; }

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
DATA_FILE="/tmp/tech-news-data.json"
DATE=$(date '+%Y-%m-%d')

CLAUDE=/Users/patric/.local/bin/claude
PYTHON3=/usr/bin/python3

# 1. Fetch 7 days of tech-news mail
"$PYTHON3" "$SCRIPT_DIR/tech-news/fetch-data.py" \
    --days 7 --label tech-news --output "$DATA_FILE" || {
  echo "fetch failed" >&2; exit 1;
}

# 2. Generate and send each format
fail=0
for fmt in A B; do
  PROMPT_FILE="$SCRIPT_DIR/tech-news/prompt-${fmt}.md"
  [[ -f "$PROMPT_FILE" ]] || { echo "missing $PROMPT_FILE" >&2; fail=1; continue; }

  prompt=$(sed -e "s|{DATA_FILE}|$DATA_FILE|g" \
               -e "s|{NOTIFY_EMAIL}|$NOTIFY_EMAIL|g" \
               -e "s|{DATE}|$DATE|g" "$PROMPT_FILE")

  echo "=== Running format $fmt ==="
  if ! "$CLAUDE" -p \
      --permission-mode bypassPermissions \
      --model claude-opus-4-7 \
      "$prompt" 2>&1 | tee "/tmp/tech-news-${fmt}.log"; then
    echo "format $fmt failed" >&2
    fail=1
  fi
done

exit "$fail"
