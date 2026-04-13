#!/usr/bin/env bash
set -uo pipefail

# Daily digest of dagu DAG runs. Sent via gws gmail to NOTIFY_EMAIL.
# Designed to run via Dagu once a day (see dagu/workflow-digest.yaml).
#
# For each DAG in ~/github/system/dagu/, summarises runs in the last 24h
# (count, ok, failed) and the latest run status. Subject line reflects
# overall health so the inbox view alone tells you if action is needed.

CONF="${HOME}/github/system/private/droplet-watchdog.conf"
[[ -f "$CONF" ]] && source "$CONF"

NOTIFY_EMAIL="${NOTIFY_EMAIL:-}"
[[ -z "$NOTIFY_EMAIL" ]] && exit 0

DAGS_DIR="${HOME}/github/system/dagu"
SELF="workflow-digest"
TODAY=$(date '+%Y-%m-%d')

DAGU=/opt/homebrew/bin/dagu

total_failed=0
total_stale=0
rows=""

for f in "$DAGS_DIR"/*.yaml; do
  dag=$(basename "$f" .yaml)

  read -r runs ok failed < <("$DAGU" history "$dag" --last 24h --format csv 2>/dev/null | awk -F',' '
    NR>1 {
      total++
      if ($3 == "Succeeded") ok++
      else if ($3 == "Failed") failed++
    }
    END { printf "%d %d %d\n", total+0, ok+0, failed+0 }
  ')

  last_line=$("$DAGU" status "$dag" 2>/dev/null | head -1)

  marker="OK  "
  if (( failed > 0 )); then
    marker="FAIL"
    total_failed=$((total_failed + failed))
  elif (( runs == 0 )) && [[ "$dag" != "$SELF" ]]; then
    marker="STALE"
    total_stale=$((total_stale + 1))
  fi

  rows+=$(printf '[%-5s] %-20s 24h: %d runs, %d ok, %d fail   latest: %s\n' \
    "$marker" "$dag" "$runs" "$ok" "$failed" "$last_line")
  rows+=$'\n'
done

if (( total_failed > 0 && total_stale > 0 )); then
  subject="[DAGU] Daily digest — ${total_failed} failures, ${total_stale} stale"
elif (( total_failed > 0 )); then
  subject="[DAGU] Daily digest — ${total_failed} failures"
elif (( total_stale > 0 )); then
  subject="[DAGU] Daily digest — ${total_stale} stale"
else
  subject="[DAGU] Daily digest — all ok"
fi

body="Dagu daily digest — ${TODAY}

${rows}
UI: http://localhost:8080"

/opt/homebrew/bin/gws gmail +send \
  --to "$NOTIFY_EMAIL" \
  --subject "$subject" \
  --body "$body" >/dev/null
