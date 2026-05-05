#!/usr/bin/env bash
set -uo pipefail

# Weekly jobs digest. Vets last 7 days of label:jobs mail against Patric's
# target-role criteria, validates top candidates via WebFetch, sends an HTML
# email to NOTIFY_EMAIL with vetted / borderline / rejected buckets.
# Designed to run via dagu (see dagu/jobs-digest.yaml).

CONF="${HOME}/github/system/private/droplet-watchdog.conf"
[[ -f "$CONF" ]] && source "$CONF"

NOTIFY_EMAIL="${NOTIFY_EMAIL:-}"
[[ -z "$NOTIFY_EMAIL" ]] && { echo "NOTIFY_EMAIL not set" >&2; exit 1; }

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
DATA_FILE="/tmp/jobs-digest-data.json"
DATE=$(date '+%Y-%m-%d')

CLAUDE=/Users/patric/.local/bin/claude
PYTHON3=/usr/bin/python3

# 1. Fetch 7 days of jobs-labelled mail
"$PYTHON3" "$SCRIPT_DIR/jobs-digest/fetch-data.py" \
    --days 7 --label jobs --output "$DATA_FILE" || {
  echo "fetch failed" >&2; exit 1;
}

# 2. Vet, validate, compose, send
PROMPT_FILE="$SCRIPT_DIR/jobs-digest/prompt.md"
[[ -f "$PROMPT_FILE" ]] || { echo "missing $PROMPT_FILE" >&2; exit 1; }

prompt=$(sed -e "s|{DATA_FILE}|$DATA_FILE|g" \
             -e "s|{NOTIFY_EMAIL}|$NOTIFY_EMAIL|g" \
             -e "s|{DATE}|$DATE|g" "$PROMPT_FILE")

echo "=== Running jobs digest ==="
"$CLAUDE" -p \
    --permission-mode bypassPermissions \
    --model claude-opus-4-7 \
    "$prompt" 2>&1 | tee /tmp/jobs-digest.log
