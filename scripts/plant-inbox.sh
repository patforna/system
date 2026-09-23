#!/usr/bin/env bash
set -uo pipefail

# Plant-selection inbox.
# =====================
# Answers what the family asked Claude on the garden app (~/github/plant-selection) and writes
# up the plants they posted as ideas. The procedure is that repo's inbox skill
# (.claude/skills/inbox/SKILL.md); this script is only the trigger.
#
# Cheap when idle: `inbox.ts pending` is one HTTP call to the app, and claude runs only when
# something waits. An idle check is the job done, so it is stamped like any success: the next
# check comes an SLO later. No droplet (the project is paused or over) is not a failure either.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/dagu-common.sh"

REPO="${PLANT_REPO:-${HOME}/github/plant-selection}"
log() { echo "[plant-inbox] $*"; }

cd "$REPO" || { log "no repo at ${REPO}"; exit 1; }

# doctl failing is a real failure; an empty list just means there is no app to serve.
ip=$(doctl compute droplet list pflanzauswahl --format PublicIPv4 --no-header) || { log "doctl failed"; exit 1; }
[[ -z "$ip" ]] && { log "no droplet: nothing to do"; exit 0; }

n=$(bun scripts/inbox.ts pending) || { log "could not read the app's state"; exit 1; }
log "${n} waiting for Claude"
(( n == 0 )) && exit 0

# One inbox run at a time (inbox.ts pull takes the lock, done releases it). A run by hand in
# progress: do nothing, and don't stamp, so the next tick tries again.
lock="var/inbox/lock"
if [[ -e "$lock" ]] && (( $(date +%s) - $(stat -f %m "$lock") < 2 * 3600 )); then
  log "another inbox run holds the lock; trying again next tick"
  touch "/tmp/dagu-noop-${DAG_NAME:-plant-inbox}"
  exit 0
fi

run_claude "Run the inbox skill (.claude/skills/inbox/SKILL.md) and work through everything waiting for Claude. This is a scheduled run: nobody is here to answer questions."
rc=$?

# However the session ended, the lock goes; a run that could not finish says so in failed.txt.
bun scripts/inbox.ts done >/dev/null
if [[ -e var/inbox/failed.txt ]]; then
  log "the run could not finish: $(cat var/inbox/failed.txt)"
  exit 1
fi
exit "$rc"
