#!/usr/bin/env bash
set -uo pipefail

# Failure notifier for dagu DAGs. Wired in via handler_on.failure in base.yaml.
# Reads DAG_NAME, DAG_RUN_ID, DAG_RUN_LOG_FILE from the dagu runtime env and
# emails a summary (with a tail of the log) to NOTIFY_EMAIL.

CONF="${HOME}/github/system/private/droplet-watchdog.conf"
[[ -f "$CONF" ]] && source "$CONF"

NOTIFY_EMAIL="${NOTIFY_EMAIL:-}"
[[ -z "$NOTIFY_EMAIL" ]] && exit 0

DAG_NAME="${DAG_NAME:-unknown}"
DAG_RUN_ID="${DAG_RUN_ID:-unknown}"
LOG_FILE="${DAG_RUN_LOG_FILE:-}"

LOG_TAIL=""
if [[ -n "$LOG_FILE" && -r "$LOG_FILE" ]]; then
  LOG_TAIL=$(tail -50 "$LOG_FILE" 2>/dev/null || true)
fi

BODY="DAG ${DAG_NAME} failed.

Run ID: ${DAG_RUN_ID}
Log:    ${LOG_FILE:-(unavailable)}
UI:     http://localhost:8080/dags/${DAG_NAME}

--- last 50 lines of log ---
${LOG_TAIL:-(no log content)}"

/opt/homebrew/bin/gws gmail +send \
  --to "$NOTIFY_EMAIL" \
  --subject "[DAGU FAIL] ${DAG_NAME}" \
  --body "$BODY" 2>/dev/null || true
