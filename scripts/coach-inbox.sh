#!/usr/bin/env bash
set -uo pipefail

# Story Coach inbox.
# ================
# Claude's read of each rehearsal take on the Story Coach recorder (~/github/story-coach/recorder). The droplet
# records and transcribes; this pulls the takes that wait for a read, makes one schema-bound `run_claude_json`
# call per take (no tools), checks the read with the quote gate (every quote must be in the transcript), and
# posts it back. The procedure's pieces live in that repo's scripts/inbox.ts; this script only drives them.
#
# Exit codes are what autofix sees, so they mean transport only:
#   - a read that misses the gate is retried once with the gate's findings, then the take is marked read-failed
#     on the server and the job still exits 0: autofix can't fix content, and must never be woken for it;
#   - a take the prompt can't be built for (a question no longer in data.json, a bar whose checks are stale)
#     is marked read-failed the same way;
#   - only an unreachable server, a claude transport failure or a failed post exits non-zero.
#
# Cheap when idle: `inbox.ts pending` is one HTTP call. No droplet is not a failure: nothing to read.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/dagu-common.sh"

REPO="${COACH_REPO:-${HOME}/github/story-coach}/recorder"
MODEL="${COACH_MODEL:-claude-opus-5-5}"
# A take's read is ~3 min. At most this many per run, and none started after the budget: the rest wait for the
# next tick, so plant-inbox behind this job in the fast lane is never held up for long.
MAX_TAKES="${COACH_MAX_TAKES:-3}"
BUDGET_SECS="${COACH_BUDGET_SECS:-1500}"
log() { echo "[coach-inbox] $*"; }
inbox() { bun scripts/inbox.ts "$@"; }

cd "$REPO" || { log "no repo at ${REPO}"; exit 1; }

n=$(inbox pending) || { log "could not read the recorder's inbox"; exit 1; }
log "${n} take(s) waiting for a read"
(( n == 0 )) && exit 0

# One run at a time. A run by hand in progress: do nothing, and don't stamp, so the next tick tries again.
mkdir -p var/inbox
lock="var/inbox/lock"
if ! mkdir "$lock" 2>/dev/null; then
  if (( $(date +%s) - $(stat -f %m "$lock") < 2 * 3600 )); then
    log "another run holds the lock; trying again next tick"
    touch "/tmp/dagu-noop-${DAG_NAME:-coach-inbox}"
    exit 0
  fi
  rm -rf "$lock" && mkdir "$lock" || exit 1
fi
trap 'rm -rf "$lock"' EXIT

ids=$(inbox pull) || { log "pull failed"; exit 1; }
start=$(date +%s)
count=0
for id in $ids; do
  if (( count >= MAX_TAKES )) || (( $(date +%s) - start > BUDGET_SECS )); then
    log "read ${count} this run; the rest wait for the next tick"
    break
  fi
  count=$((count + 1))

  prompt_file="var/inbox/${id}.prompt.md"
  schema_file="var/inbox/${id}.schema.json"
  err_file="var/inbox/${id}.err"
  for part in prompt schema; do
    out="$prompt_file"; [[ $part == schema ]] && out="$schema_file"
    inbox "$part" "$id" > "$out" 2> "$err_file"
    rc=$?
    if (( rc == 3 )); then
      log "take ${id}: $(cat "$err_file")"
      inbox fail "$id" "Not read: $(sed 's/^inbox: //' "$err_file")" || exit 1
      continue 2
    fi
    (( rc == 0 )) || { log "take ${id}: building the ${part} failed: $(cat "$err_file")"; exit 1; }
  done

  prompt=$(cat "$prompt_file")
  schema=$(cat "$schema_file")
  feedback=""
  passed=0
  for attempt in 1 2; do
    run_claude_json "$MODEL" "$schema" "${prompt}${feedback}" > "var/inbox/${id}.envelope.json"
    rc=$?
    (( rc == 0 )) || { log "take ${id}: claude transport failure (rc=${rc})"; exit 1; }
    problems=$(inbox check "$id" "var/inbox/${id}.envelope.json")
    rc=$?
    if (( rc == 0 )); then passed=1; break; fi
    (( rc == 3 )) || { log "take ${id}: the gate could not run (rc=${rc})"; exit 1; }
    log "take ${id}: attempt ${attempt} missed the gate:"
    echo "$problems"
    feedback=$'\n\n## Your previous read was rejected\n\nIt failed these checks. Answer again, fixing every one; quote word for word.\n\n'"${problems}"
  done

  if (( passed )); then
    inbox post "$id" --model "$MODEL" || exit 1
  else
    inbox fail "$id" "The read missed the quote gate twice. Last findings: ${problems}" || exit 1
  fi
done
exit 0
