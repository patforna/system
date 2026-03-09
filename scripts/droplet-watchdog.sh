#!/usr/bin/env bash
set -uo pipefail

# Alert if the dev droplet has been running longer than 24 hours.
# Sends an email via Mail.app and a macOS notification.
#
# Usage: droplet-watchdog.sh
# Designed to run via Dagu every 4 hours.

DROPLET_NAME="dev"
ALERT_AFTER_HOURS=24
CONF="${HOME}/Drive/system/droplet-watchdog.conf"

if [[ ! -f "$CONF" ]]; then
  exit 0  # no config, nothing to do
fi
source "$CONF"  # expects NOTIFY_EMAIL

# --- Preflight ---
if ! command -v doctl &>/dev/null; then
  exit 0  # doctl not installed, nothing to check
fi

# --- Check if droplet exists ---
DROPLET_ID=$(doctl compute droplet list "$DROPLET_NAME" --format ID --no-header 2>/dev/null || true)
if [[ -z "$DROPLET_ID" ]]; then
  exit 0  # no droplet running
fi

# --- Get creation time ---
CREATED_AT=$(doctl compute droplet actions "$DROPLET_ID" --output json 2>/dev/null \
  | python3 -c "
import sys, json
actions = json.load(sys.stdin)
create = next((a for a in actions if a['type'] == 'create'), None)
print(create['started_at'] if create else '')
" 2>/dev/null || true)

if [[ -z "$CREATED_AT" ]]; then
  CREATED_AT=$(doctl compute droplet get "$DROPLET_ID" --output json 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['created_at'])" 2>/dev/null || true)
fi

if [[ -z "$CREATED_AT" ]]; then
  exit 0  # can't determine age
fi

# --- Calculate uptime ---
CREATED_EPOCH=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$CREATED_AT" +%s 2>/dev/null || date -d "$CREATED_AT" +%s)
NOW_EPOCH=$(date +%s)
UPTIME_HOURS=$(( (NOW_EPOCH - CREATED_EPOCH) / 3600 ))

if (( UPTIME_HOURS < ALERT_AFTER_HOURS )); then
  exit 0  # still within threshold
fi

UPTIME_DAYS=$(( UPTIME_HOURS / 24 ))
UPTIME_REM=$(( UPTIME_HOURS % 24 ))

# --- Send macOS notification ---
osascript -e "display notification \"Dev droplet running for ${UPTIME_DAYS}d ${UPTIME_REM}h. Run dev-down to stop billing.\" with title \"Droplet Watchdog\"" 2>/dev/null || true

# --- Send email via gog ---
if command -v gog &>/dev/null; then
  gog gmail send \
    --to "$NOTIFY_EMAIL" \
    --subject "Dev droplet running for ${UPTIME_DAYS}d ${UPTIME_REM}h" \
    --body "Your DigitalOcean dev droplet has been running for ${UPTIME_DAYS} days and ${UPTIME_REM} hours.

Run dev-down to snapshot and destroy it.

— droplet-watchdog" \
    --force 2>/dev/null || true
fi
