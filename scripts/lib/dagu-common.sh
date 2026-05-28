# scripts/lib/dagu-common.sh — sourced by the claude-invoking DAG scripts.
# Assumes the caller has set -uo pipefail.
DAGU_COMMON_CONF="${HOME}/github/system/private/droplet-watchdog.conf"
[[ -f "$DAGU_COMMON_CONF" ]] && source "$DAGU_COMMON_CONF"
NOTIFY_EMAIL="${NOTIFY_EMAIL:-}"

CLAUDE="${CLAUDE:-${HOME}/.local/bin/claude}"
GWS="${GWS:-/opt/homebrew/bin/gws}"
GH="${GH:-/opt/homebrew/bin/gh}"
PYTHON3="${PYTHON3:-/usr/bin/python3}"

# Fail-loud guard for scripts that cannot run without an address (digests).
require_notify_email() {
  [[ -z "$NOTIFY_EMAIL" ]] && { echo "NOTIFY_EMAIL not set" >&2; exit 1; }
}

# Single chokepoint for the headless-claude invocation (model id + flags live
# in ONE place). Caller wraps cd/tee/redirection around it as today.
run_claude() {
  "$CLAUDE" -p --permission-mode bypassPermissions --model claude-opus-4-7 "$@"
}

# Append a fallback JSONL line iff claude never recorded one for this run.
record_fallback() {
  local state_file="$1" dag="$2" run_id="$3" ts="$4" outcome="$5" note="$6"
  if ! grep -q "\"run_id\":\"$run_id\"" "$state_file" 2>/dev/null; then
    echo "{\"ts\":\"$ts\",\"dag\":\"$dag\",\"run_id\":\"$run_id\",\"outcome\":\"$outcome\",\"note\":\"$note\",\"commit\":\"\"}" >> "$state_file"
  fi
}
