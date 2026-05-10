#!/usr/bin/env bash
set -uo pipefail

# Daily digest of dagu DAG runs. Sent via gws gmail to NOTIFY_EMAIL.
# Designed to run via Dagu once a day (see dagu/workflow-digest.yaml).
#
# Two states per row: OK / ATTN. Anything that needs human attention
# (escalation, unhandled failure, scheduler didn't fire) is ATTN; everything
# else is OK. The row's free-text comment carries the detail — for failed
# runs it's the latest autofix `note` field, written by the per-failure
# Claude session.

CONF="${HOME}/github/system/private/droplet-watchdog.conf"
[[ -f "$CONF" ]] && source "$CONF"

NOTIFY_EMAIL="${NOTIFY_EMAIL:-}"
[[ -z "$NOTIFY_EMAIL" ]] && exit 0

DAGS_DIR="${HOME}/github/system/dagu"
SELF="workflow-digest"
TODAY=$(date '+%Y-%m-%d')

DAGU=/opt/homebrew/bin/dagu
AUTOFIX_LOG="${HOME}/.local/state/dagu-autofix.jsonl"

AUTOFIX_SINCE_24H=$(date -u -v-24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-24 hours' +%Y-%m-%dT%H:%M:%SZ)
AUTOFIX_SINCE_7D=$(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-7 days' +%Y-%m-%dT%H:%M:%SZ)

# Latest autofix entry for one DAG within a window. Prints "<outcome>\t<note>"
# or empty if none. Requires jq.
latest_autofix() {
  local dag="$1" since="$2"
  [[ -f "$AUTOFIX_LOG" ]] || return
  jq -r --arg dag "$dag" --arg since "$since" \
    'select(.dag == $dag and .ts >= $since) | "\(.outcome)\t\(.note)"' \
    "$AUTOFIX_LOG" 2>/dev/null | tail -1
}

attn_count=0
note_count=0
rows=""

for f in "$DAGS_DIR"/*.yaml; do
  dag=$(basename "$f" .yaml)

  schedule=$(awk -F'"' '/^schedule:/ {print $2; exit}' "$f")
  dow=$(echo "$schedule" | awk '{print $5}')
  if [[ -n "$dow" && "$dow" != "*" ]]; then
    window="7d"
    autofix_since="$AUTOFIX_SINCE_7D"
  else
    window="24h"
    autofix_since="$AUTOFIX_SINCE_24H"
  fi

  read -r runs ok failed < <("$DAGU" history "$dag" --last "$window" --format csv 2>/dev/null | awk -F',' '
    NR>1 {
      total++
      if ($3 == "Succeeded") ok++
      else if ($3 == "Failed") failed++
    }
    END { printf "%d %d %d\n", total+0, ok+0, failed+0 }
  ')

  af=$(latest_autofix "$dag" "$autofix_since")
  af_outcome=""
  af_note=""
  if [[ -n "$af" ]]; then
    af_outcome="${af%%$'\t'*}"
    af_note="${af#*$'\t'}"
  fi

  marker="OK  "
  comment=""

  if (( failed > 0 )); then
    if [[ -n "$af_outcome" ]]; then
      comment="$af_note"
      if [[ "$af_outcome" == "escalated" || "$af_outcome" == "unhandled" ]]; then
        marker="ATTN"
        attn_count=$((attn_count + 1))
      else
        note_count=$((note_count + 1))
      fi
    else
      marker="ATTN"
      comment="failure with no autofix record — autofix may not be wired or crashed"
      attn_count=$((attn_count + 1))
    fi
  elif (( runs == 0 )) && [[ "$dag" != "$SELF" ]]; then
    last_line=$("$DAGU" status "$dag" 2>/dev/null | head -1)
    if [[ -z "$last_line" ]]; then
      comment="never run yet"
      note_count=$((note_count + 1))
    else
      marker="ATTN"
      comment="no runs in ${window} — scheduler may not have fired"
      attn_count=$((attn_count + 1))
    fi
  fi

  if [[ -n "$comment" ]]; then
    rows+=$(printf '%s  %-20s  %d/%d in %-3s  — %s\n' "$marker" "$dag" "$ok" "$runs" "$window" "$comment")
  else
    rows+=$(printf '%s  %-20s  %d/%d in %s\n' "$marker" "$dag" "$ok" "$runs" "$window")
  fi
  rows+=$'\n'
done

if (( attn_count > 0 )); then
  subject="[DAGU] Daily digest — ${attn_count} need attention"
elif (( note_count > 0 )); then
  subject="[DAGU] Daily digest — all ok (${note_count} notes)"
else
  subject="[DAGU] Daily digest — all ok"
fi

body="Dagu daily digest — ${TODAY}

${rows}
Markers: OK / ATTN. Comments come from the per-failure autofix session.

UI: http://localhost:8080"

/opt/homebrew/bin/gws gmail +send \
  --to "$NOTIFY_EMAIL" \
  --subject "$subject" \
  --body "$body" >/dev/null
