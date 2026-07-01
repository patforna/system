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

# Per-attempt wall-clock cap on ONE claude invocation. A hung session (claude
# started but emits nothing and never exits — seen 07-01, killed only by the DAG
# timeout after ~3h, which SIGKILLed the whole script mid-teardown and stranded a
# worktree) is invisible to the transient-retry below, which only fires on a
# non-zero EXIT. This bounds it: `gtimeout -k` sends TERM then KILL after a
# grace, so the invocation returns non-zero (124 TERM / 137 KILL) instead of
# hanging, and the retry/teardown logic runs normally. Preferred impl is
# coreutils `gtimeout`; if it's ever missing we fall back to a pure-bash
# watchdog that TERM→KILLs claude's process group, so the cap holds even without
# the dependency. See system GOTCHAS.md "tad-daily-code-review hangs".
#
# Value reconciles with the callers' DAG timeout_sec (all 5400s / 90m): the
# script-level retry must finish INSIDE that window or the (loose, proven
# unreliable) dagu timer cuts in mid-retry and SIGKILLs the script again. With
# MAX_ATTEMPTS=3 and the 30+60s backoffs: 3*1500 + 90 = 4590s < 5400s. 25m/attempt
# is also generous against the healthy path (minutes) — a single attempt running
# longer is degenerate (hung, or claude internally grinding on a slow API night),
# exactly what we want to cap and retry rather than let grind for hours.
CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT:-1500}"   # seconds per attempt
CLAUDE_TIMEOUT_KILL_GRACE="${CLAUDE_TIMEOUT_KILL_GRACE:-60}"
GTIMEOUT="${GTIMEOUT:-$(command -v gtimeout || command -v timeout || true)}"

# Run "$@" with a wall-clock cap. Exit 124 = timed out (TERM), 137 = had to be
# KILLed after the grace. stdout/stderr stream through so the caller's tee sees
# live output. Uses gtimeout when present, else a bash-job-control watchdog.
_run_with_timeout() {
  local secs="$1"; shift
  if [[ -n "$GTIMEOUT" ]]; then
    "$GTIMEOUT" -k "$CLAUDE_TIMEOUT_KILL_GRACE" "$secs" "$@"
    return $?
  fi
  # Fallback: run the command in its own process group (job control), and a
  # detached watchdog TERM→KILLs that whole group on deadline — reaping claude's
  # node/MCP children too (a bare `kill <pid>` would orphan them, the exact
  # reap-failure that let the hang run for 3h).
  local had_m=0; case "$-" in *m*) had_m=1;; esac
  set -m
  "$@" &
  local pid=$!
  ( sleep "$secs"; kill -TERM "-$pid" 2>/dev/null
    sleep "$CLAUDE_TIMEOUT_KILL_GRACE"; kill -KILL "-$pid" 2>/dev/null ) &
  local watch=$!
  wait "$pid"; local rc=$?
  kill "$watch" 2>/dev/null; wait "$watch" 2>/dev/null
  (( had_m )) || set +m
  # Normalise a signal death (rc = 128 + signum) to the gtimeout convention so
  # the caller's retry test is impl-agnostic: TERM(15)->124, KILL(9)->137.
  case "$rc" in 143) rc=124;; 137) rc=137;; esac
  return "$rc"
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
# A per-attempt timeout (124/137) is treated as transient too — a hang is usually
# self-clearing, so retry within the run rather than burning the whole DAG.
CLAUDE_MAX_ATTEMPTS="${CLAUDE_MAX_ATTEMPTS:-3}"
run_claude() {
  local attempt rc cap
  cap=$(mktemp -t run_claude.XXXXXX)
  for ((attempt = 1; attempt <= CLAUDE_MAX_ATTEMPTS; attempt++)); do
    : > "$cap"
    _run_with_timeout "$CLAUDE_TIMEOUT" \
      "$CLAUDE" -p --permission-mode bypassPermissions --model claude-opus-4-8 "$@" 2>&1 | tee "$cap"
    rc=${PIPESTATUS[0]}
    if (( rc == 0 )); then rm -f "$cap"; return 0; fi
    if (( attempt < CLAUDE_MAX_ATTEMPTS )) \
       && { (( rc == 124 || rc == 137 )) \
            || grep -qiE 'API Error|connection closed|connection reset|socket connection|overloaded|rate.?limit|read timed out|request timed out' "$cap"; }; then
      if (( rc == 124 || rc == 137 )); then
        echo "[run_claude] attempt ${attempt}/${CLAUDE_MAX_ATTEMPTS} timed out after ${CLAUDE_TIMEOUT}s (rc=${rc}); retrying after $((attempt * 30))s backoff." >&2
      else
        echo "[run_claude] transient API failure (attempt ${attempt}/${CLAUDE_MAX_ATTEMPTS}, rc=${rc}); retrying after $((attempt * 30))s backoff." >&2
      fi
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
