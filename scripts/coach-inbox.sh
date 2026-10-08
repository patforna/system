#!/usr/bin/env bash
set -uo pipefail

# Story Coach inbox.
# ================
# Claude's read of each rehearsal take on the Story Coach recorder (~/github/story-coach/recorder). The droplet
# records and transcribes; this pulls the takes that wait for a read, makes one schema-bound `run_claude_json`
# call per take (no tools), checks the read with the gate (every quote must be in the transcript, and v3's rules
# besides), and posts it back. The procedure's pieces live in that repo's scripts/inbox.ts; this script only
# drives them.
#
# READ_VERSION picks the read (voice/READ-V3.md in that repo). v2: the prompt, one plain call, the gate. v3 adds
# his Core Stories from Notion (cached an hour), a context step (his pace, the previous read of the question) and
# a pre-pass on a cheap model (where each part of the answer starts; a failed pre-pass only drops the parts
# table), and makes the read a lean call with its own system prompt.
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
# v3 since it passed the eval (recorder/scripts/eval-read, voice/read-v3/eval-log.md); READ_VERSION=v2 for the old read.
export READ_VERSION="${READ_VERSION:-v3}"
# A take's read is ~3 min. At most this many per run, and none started after the budget: the rest wait for the
# next tick, so plant-inbox behind this job in the fast lane is never held up for long.
MAX_TAKES="${COACH_MAX_TAKES:-3}"
BUDGET_SECS="${COACH_BUDGET_SECS:-1500}"
log() { echo "[coach-inbox] $*"; }
inbox() { bun scripts/inbox.ts "$@"; }

cd "$REPO" || { log "no repo at ${REPO}"; exit 1; }

n=$(inbox pending) || { log "could not read the recorder's inbox"; exit 1; }
log "${n} take(s) waiting for a read (${READ_VERSION})"
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
# v3: his Core Stories from Notion, at most once an hour; without them the reads flag no omission.
[[ $READ_VERSION == v3 ]] && { inbox core-stories || log "fetching the Core Stories crashed; reading with the copy there is"; }
start=$(date +%s)
count=0
for id in $ids; do
  if (( count >= MAX_TAKES )) || (( $(date +%s) - start > BUDGET_SECS )); then
    log "read ${count} this run; the rest wait for the next tick"
    break
  fi
  count=$((count + 1))

  err_file="var/inbox/${id}.err"
  if [[ $READ_VERSION == v3 ]]; then
    inbox context "$id" || { log "take ${id}: the context step failed"; exit 1; }
    inbox segment "$id" || log "take ${id}: the pre-pass crashed; reading without the parts table"
  fi
  for part in prompt schema system; do
    out="var/inbox/${id}.${part}.md"; [[ $part == schema ]] && out="var/inbox/${id}.schema.json"
    inbox "$part" "$id" > "$out" 2> "$err_file"
    rc=$?
    if (( rc == 3 )); then
      log "take ${id}: $(cat "$err_file")"
      inbox fail "$id" "Not read: $(sed 's/^inbox: //' "$err_file")" || exit 1
      continue 2
    fi
    (( rc == 0 )) || { log "take ${id}: building the ${part} failed: $(cat "$err_file")"; exit 1; }
  done

  prompt=$(cat "var/inbox/${id}.prompt.md")
  schema=$(cat "var/inbox/${id}.schema.json")
  # Empty for v2: a plain call. v3's makes it lean.
  system=$(cat "var/inbox/${id}.system.md")
  passed=0
  for attempt in 1 2; do
    run_claude_json "$MODEL" "$schema" "$prompt" "" "$system" > "var/inbox/${id}.envelope.json"
    rc=$?
    (( rc == 0 )) || { log "take ${id}: claude transport failure (rc=${rc})"; exit 1; }
    # The last attempt keeps a v3 read with faults of form, as warnings, rather than lose it.
    final=""; (( attempt == 2 )) && final="--final"
    problems=$(inbox check "$id" "var/inbox/${id}.envelope.json" $final)
    rc=$?
    if (( rc == 0 )); then passed=1; break; fi
    (( rc == 3 )) || { log "take ${id}: the gate could not run (rc=${rc})"; exit 1; }
    log "take ${id}: attempt ${attempt} missed the gate:"
    echo "$problems"
    # The prompt again, with the findings to fix (inbox.ts check wrote it).
    prompt=$(cat "var/inbox/${id}.retry.md")
  done

  if (( passed )); then
    inbox post "$id" --model "$MODEL" || exit 1
  else
    inbox fail "$id" "The read missed the gate twice. Last findings: ${problems}" || exit 1
  fi
done
exit 0
