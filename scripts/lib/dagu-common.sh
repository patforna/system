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
#
# Bounded retry on TRANSIENT API/connection blips only. `claude -p` periodically
# drops the streaming connection mid-response ("API Error: Connection closed
# mid-response", socket-close, overload, rate-limit) and exits non-zero on a
# self-clearing fault. base.yaml's retry_policy absorbs this for most DAGs, but
# tad-daily-code-review opts out (limit 0 — each dagu retry burns a full worktree
# + review session) and relies on "the script retries at its own level": that
# retry lives HERE. A genuine non-zero crash (no transient marker in the output)
# returns immediately and still fails the DAG. Output streams live to the caller
# (tee/log keeps growing for liveness) while being captured for pattern-matching.
CLAUDE_MAX_ATTEMPTS="${CLAUDE_MAX_ATTEMPTS:-3}"
run_claude() {
  local attempt rc cap
  cap=$(mktemp -t run_claude.XXXXXX)
  for ((attempt = 1; attempt <= CLAUDE_MAX_ATTEMPTS; attempt++)); do
    : > "$cap"
    "$CLAUDE" -p --permission-mode bypassPermissions --model claude-opus-4-8 "$@" 2>&1 | tee "$cap"
    rc=${PIPESTATUS[0]}
    if (( rc == 0 )); then rm -f "$cap"; return 0; fi
    if (( attempt < CLAUDE_MAX_ATTEMPTS )) \
       && grep -qiE 'API Error|connection closed|connection reset|socket connection|overloaded|rate.?limit|read timed out|request timed out' "$cap"; then
      echo "[run_claude] transient API failure (attempt ${attempt}/${CLAUDE_MAX_ATTEMPTS}, rc=${rc}); retrying after $((attempt * 30))s backoff." >&2
      sleep $((attempt * 30))
      continue
    fi
    rm -f "$cap"; return "$rc"
  done
  rm -f "$cap"; return "$rc"
}

# Append a fallback JSONL line iff claude never recorded one for this run.
record_fallback() {
  local state_file="$1" dag="$2" run_id="$3" ts="$4" outcome="$5" note="$6"
  if ! grep -q "\"run_id\":\"$run_id\"" "$state_file" 2>/dev/null; then
    echo "{\"ts\":\"$ts\",\"dag\":\"$dag\",\"run_id\":\"$run_id\",\"outcome\":\"$outcome\",\"note\":\"$note\",\"commit\":\"\"}" >> "$state_file"
  fi
}
