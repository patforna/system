#!/usr/bin/env bash
set -uo pipefail

# Daily digest of dagu DAG runs. Sent via gws gmail to NOTIFY_EMAIL.
# Designed to run via Dagu once a day (see dagu/workflow-digest.yaml).
#
# For each DAG in ~/github/system/dagu/, summarises runs in the last 24h
# (count, ok, failed) and joins against the autofix log so failures that were
# auto-fixed don't look like open problems. The subject line only counts
# failures that need human attention.

CONF="${HOME}/github/system/private/droplet-watchdog.conf"
[[ -f "$CONF" ]] && source "$CONF"

NOTIFY_EMAIL="${NOTIFY_EMAIL:-}"
[[ -z "$NOTIFY_EMAIL" ]] && exit 0

DAGS_DIR="${HOME}/github/system/dagu"
SELF="workflow-digest"
TODAY=$(date '+%Y-%m-%d')

DAGU=/opt/homebrew/bin/dagu
AUTOFIX_LOG="${HOME}/.local/state/dagu-autofix.jsonl"

# Cut-off for autofix entries we care about: anything with ts >= now - 7d
# (a generous window — the per-DAG window below filters again).
AUTOFIX_SINCE_24H=$(date -u -v-24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-24 hours' +%Y-%m-%dT%H:%M:%SZ)
AUTOFIX_SINCE_7D=$(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-7 days' +%Y-%m-%dT%H:%M:%SZ)

# Count autofix outcomes for one DAG within a window.
# Args: dag_name, since_ts, outcome
count_autofix() {
  local dag="$1" since="$2" outcome="$3"
  [[ -f "$AUTOFIX_LOG" ]] || { echo 0; return; }
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg dag "$dag" --arg since "$since" --arg outcome "$outcome" \
      'select(.dag == $dag and .ts >= $since and .outcome == $outcome) | .outcome' \
      "$AUTOFIX_LOG" 2>/dev/null | wc -l | tr -d ' '
  else
    grep -c "\"dag\":\"$dag\".*\"outcome\":\"$outcome\"" "$AUTOFIX_LOG" 2>/dev/null || echo 0
  fi
}

total_failed_unhandled=0
total_escalated=0
total_fixed=0
total_stale=0
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

  fixed=$(count_autofix "$dag" "$autofix_since" "fixed")
  escalated=$(count_autofix "$dag" "$autofix_since" "escalated")
  transient=$(count_autofix "$dag" "$autofix_since" "transient")
  unhandled=$(count_autofix "$dag" "$autofix_since" "unhandled")

  last_line=$("$DAGU" status "$dag" 2>/dev/null | head -1)

  marker="OK   "
  autofix_note=""
  if (( escalated > 0 )); then
    marker="ESC  "
    total_escalated=$((total_escalated + escalated))
    autofix_note=$(printf "  autofix: %d escalated" "$escalated")
  elif (( failed > 0 )); then
    handled=$((fixed + transient + unhandled))
    if (( unhandled > 0 || handled < failed )); then
      marker="FAIL "
      total_failed_unhandled=$((total_failed_unhandled + (failed - fixed - transient)))
    elif (( fixed > 0 )); then
      marker="FIX  "
      total_fixed=$((total_fixed + fixed))
    else
      marker="TRAN "
    fi
    parts=""
    (( fixed > 0 )) && parts+="${fixed} fixed, "
    (( transient > 0 )) && parts+="${transient} transient, "
    (( unhandled > 0 )) && parts+="${unhandled} unhandled, "
    parts="${parts%, }"
    [[ -n "$parts" ]] && autofix_note=$(printf "  autofix: %s" "$parts")
  elif (( runs == 0 )) && [[ "$dag" != "$SELF" ]]; then
    if [[ -z "$last_line" ]]; then
      marker="PEND "
    else
      marker="STALE"
      total_stale=$((total_stale + 1))
    fi
  fi

  rows+=$(printf '[%s] %-20s %-3s: %d runs, %d ok, %d fail   latest: %s%s\n' \
    "$marker" "$dag" "$window" "$runs" "$ok" "$failed" "$last_line" "$autofix_note")
  rows+=$'\n'
done

if (( total_escalated > 0 )); then
  subject="[DAGU] Daily digest — ${total_escalated} need human"
elif (( total_failed_unhandled > 0 )); then
  subject="[DAGU] Daily digest — ${total_failed_unhandled} unhandled failures"
elif (( total_stale > 0 )); then
  subject="[DAGU] Daily digest — ${total_stale} stale"
elif (( total_fixed > 0 )); then
  subject="[DAGU] Daily digest — all ok (${total_fixed} autofixed)"
else
  subject="[DAGU] Daily digest — all ok"
fi

body="Dagu daily digest — ${TODAY}

${rows}
Markers: OK / FIX (autofixed) / TRAN (transient, no action) / ESC (needs human) / FAIL (unhandled) / STALE / PEND

UI: http://localhost:8080"

/opt/homebrew/bin/gws gmail +send \
  --to "$NOTIFY_EMAIL" \
  --subject "$subject" \
  --body "$body" >/dev/null
