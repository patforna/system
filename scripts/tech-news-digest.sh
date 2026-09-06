#!/usr/bin/env bash
set -uo pipefail

# Weekly tech-news digest. Sends an HN-style ranked email to NOTIFY_EMAIL
# built from 7 days of label:tech-news mail. Designed to run via dagu (see
# dagu/tech-news-digest.yaml).
#
# The script owns the pipeline; claude only does judgment. Phases: chunked
# extraction (haiku, schema-bound JSON), a script-computed coverage gate,
# link canonicalisation + exact-duplicate merge in code, ONE ranking call
# (opus) over compact item ids, and a code-rendered HTML template — the model
# never emits HTML or re-emits item content, which removes the old
# whole-corpus render's silent-failure modes (partial reads, invented links,
# malformed markup). See scripts/tech-news/pipeline.py.
#
# Keeping the +send out of the model loop avoids alias / PATH surprises in the
# Bash tool's shell (e.g. zsh `alias cat='bat'` silently emptying --body).

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/dagu-common.sh"
require_notify_email

# Single-run lock. Any trigger path can start a second run: base.yaml's
# `overlap_policy: skip` governs SCHEDULER-triggered runs, and this system has
# no schedules — dagu-reconcile (and a human) both use `dagu start`, which
# bypasses it. Two runs would then race the shared Gmail fetch and each other's
# scratch state. Observed in jobs-digest on 2026-08-20, before its scratch
# paths were per-run: the losing run died on a missing merged.json, then
# validated its scoring against a swapped candidate set, sent nothing, and
# escalated. Scratch paths are per-run here too (below), which removes the
# corruption; the lock still stops two runs racing the Gmail fetch and paying
# for the same extraction twice.
#
# mkdir is the atomic acquire. The pid file is written immediately after, so a
# competitor can arrive in between and see an empty pid — treating that as
# stale would let it delete a live run's lock, which is the exact overlap this
# guards. An absent pid is therefore "held" while the lock is young, and only
# stale once far older than any plausible start-up. A live pid holding a lock
# older than the DAG's own timeout means the pid was recycled, so age overrides
# liveness there too. Exit 0, never 1: a skipped duplicate is not a failure and
# must not wake the autofix handler — that is what turned one collision into a
# cascade. The no-op flag keeps that exit 0 from stamping the SLO marker.
LOCK_DIR="/tmp/tech-news-digest.lock"
LOCK_STALE_SECS=${LOCK_STALE_SECS:-10800}   # 3h; the DAG's own cap is 5400s
NOOP_FLAG="/tmp/dagu-noop-${DAG_NAME:-tech-news-digest}"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  holder=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
  age=$(( $(date +%s) - $(stat -f %m "$LOCK_DIR" 2>/dev/null || echo 0) ))
  if [[ -n "$holder" ]]; then
    kill -0 "$holder" 2>/dev/null && (( age < LOCK_STALE_SECS )) && held=1 || held=0
  else
    (( age < 60 )) && held=1 || held=0   # holder mid-acquire, not stale
  fi
  if (( held )); then
    touch "$NOOP_FLAG"
    echo "another tech-news-digest run (pid ${holder:-starting}) is in flight — skipping" >&2
    exit 0
  fi
  echo "clearing stale tech-news-digest lock (pid ${holder:-unknown}, age ${age}s)" >&2
  rm -rf "$LOCK_DIR"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    touch "$NOOP_FLAG"
    echo "another tech-news-digest run took the lock first — skipping" >&2
    exit 0
  fi
fi
echo $$ > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR"' EXIT
# This run is doing the work, so clear any no-op flag a skipped sibling left.
rm -f "$NOOP_FLAG"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# Scratch paths are per-run, keyed on the dagu run id (PID fallback for a
# manual `bash` run) — the jobs-digest 2026-08-20 fix, see private/GOTCHAS.md.
# The extraction workers below make this load-bearing: a forced stop can leave
# a worker's claude call running past this run, and with fixed paths the next
# run's startup `rm -rf` would rebuild the tree under it and adopt whatever the
# straggler then wrote as its own extraction.
RUN_TAG="${DAG_RUN_ID:-manual-$$}"
DATA_FILE="/tmp/tech-news-data-${RUN_TAG}.json"
WORK_DIR="/tmp/tech-news-work-${RUN_TAG}"
HTML_FILE="/tmp/tech-news-${RUN_TAG}.html"
PIPELINE="$SCRIPT_DIR/tech-news/pipeline.py"
DATE=$(date '+%Y-%m-%d')

EXTRACT_MODEL="claude-haiku-4-5-20251001"
RANK_MODEL="claude-opus-4-8"

# The prompt/schema files are cat'd unchecked below — fail fast before any
# fetch or extraction work rather than feed claude an empty prompt.
for f in tech-news/extraction-prompt.md tech-news/extraction-schema.json \
         tech-news/ranking-prompt.md tech-news/ranking-schema.json; do
  [[ -s "$SCRIPT_DIR/$f" ]] || { echo "$f missing or empty" >&2; exit 1; }
done

# Body-character budget per extraction chunk. A runtime lever, with
# EXTRACT_WIDTH below: smaller chunks mean more (but faster, more reliable)
# haiku calls; the whole run must stay inside the DAG's timeout (10800s — a
# 24-chunk week extracts in ~20 min at width 4). Must also stay well under
# ARG_MAX (~1MB) — the chunk JSON travels inline in the prompt argument,
# since the extraction calls run tool-less and cannot read files.
CHUNK_BUDGET="${TECH_NEWS_CHUNK_BUDGET:-80000}"

# Extraction calls in flight at once. Each is a node process idling on a
# ~3-minute API response, so a few cost little locally; the unknowns are
# API-side (rate limits, whether concurrent calls each run slower), which is
# why this is 4 and not 24.
EXTRACT_WIDTH="${TECH_NEWS_EXTRACT_WIDTH:-4}"
# A width of 0 (or junk) would launch nothing, report full coverage and rank
# an empty list — a silent wrong digest — so refuse it here. 16 is a typo
# bound, not a tuning: beyond it the API side is the unknown.
[[ "$EXTRACT_WIDTH" =~ ^[1-9][0-9]?$ ]] && (( EXTRACT_WIDTH <= 16 )) || {
  echo "TECH_NEWS_EXTRACT_WIDTH must be 1-16, got '$EXTRACT_WIDTH'" >&2; exit 1;
}

# 1. Fetch 7 days of tech-news mail. Primary: the local msgvault archive —
# reads touch Gmail zero times, so the gws exit-5 failure mode (~100 sequential
# message.get calls) is gone entirely (see private/GOTCHAS.md). Fallback: the
# gws fetcher, used when msgvault is missing/stale/returns too little, so a
# broken archive never loses a digest. The count<30 floor below is the final
# guard regardless of source.
fetched_via="msgvault"
# --exclude-subject drops this digest's own past emails, which carry
# label:tech-news and would otherwise be re-ingested as source material.
if ! "$PYTHON3" "$SCRIPT_DIR/lib/fetch-msgvault-label.py" \
       --days 7 --label tech-news --exclude-subject "Tech-news digest" \
       --output "$DATA_FILE" \
   || (( $(jq length "$DATA_FILE" 2>/dev/null || echo 0) < 30 )); then
  echo "msgvault fetch unavailable or thin — falling back to gws" >&2
  fetched_via="gws"
  "$PYTHON3" "$SCRIPT_DIR/lib/fetch-gmail-label.py" \
      --days 7 --label tech-news --exclude-subject "Tech-news digest" \
      --output "$DATA_FILE" || {
    echo "fetch failed" >&2; exit 1;
  }
fi
echo "fetched via $fetched_via" >&2

# A healthy week is ~90-120 messages; near-zero from both sources means the
# Gmail filter or label broke (see scripts/tech-news/senders.txt), not a quiet
# week — fail into the autofix path rather than email a hollow digest.
count=$(jq length "$DATA_FILE")
if (( count < 30 )); then
  echo "only $count messages fetched (norm ~100) — tech-news filter/label likely broken" >&2
  exit 1
fi

# 2. Chunk. WORK_DIR keeps every intermediate (chunks, claude envelopes,
# validated items, merged list, ranking) for post-mortems. The dir is per-run
# and unique by construction, so nothing stale can leak in; sweep siblings
# older than 2 days so per-run dirs don't accumulate in /tmp (the +2 age can't
# touch a live run).
find /tmp -maxdepth 1 -name 'tech-news-work-*' -type d -mtime +2 -exec rm -rf {} + 2>/dev/null || true
find /tmp -maxdepth 1 -type f \( -name 'tech-news-data-*.json' -o -name 'tech-news-*.html' \) -mtime +2 -delete 2>/dev/null || true
rm -rf "$WORK_DIR"
rm -f "$HTML_FILE"
mkdir -p "$WORK_DIR/chunks" "$WORK_DIR/items"
"$PYTHON3" "$PIPELINE" chunk --input "$DATA_FILE" \
    --outdir "$WORK_DIR/chunks" --budget "$CHUNK_BUDGET" || {
  echo "chunking failed" >&2; exit 1;
}

# 3. Extraction: one haiku call per chunk against the extraction schema,
# EXTRACT_WIDTH chunks in flight at once. Ran sequentially until 09-03 (a
# claude process is heavy; readable logs), but 24-25 calls at ~3 min each is
# ~80 min — the whole DAG window — and the run was reaped mid-Ranking three
# times that day (see private/GOTCHAS.md). Two retry layers, deliberately
# distinct: run_claude_json retries TRANSPORT faults (API blips, hangs)
# internally — a chunk it still fails on is failed outright, never re-retried
# here; extract_chunk's attempts are consumed only by semantically INVALID
# responses (structured_output null, alien message ids), twice, then the
# chunk is marked failed and the run carries on. The per-attempt cap drops to
# 600s for this phase only: a healthy call is 1-5 min (79 sleep-corrected
# calls on 09-03: p50 183s, p95 281s, max 295s — `claude -p --json-schema`
# generates the answer twice, as text and then through the structured-output
# tool), so the default 1500s would let one hang idle a slot for most of the
# window, while the previous 300s sat inside that tail and killed several
# slow-but-healthy calls per run mid-generation or in teardown (the rc=124
# retries, ~5.5 min each). Those were never hangs.
#
# No `wait -n` in bash 3.2 (dagu's interpreter, see GOTCHAS), so the pool is
# a short poll over the slots: reap what has finished, refill free slots, and
# stop feeding it the moment the coverage gate below is already lost — what
# is still in flight is then killed rather than left to burn up to three
# capped attempts each, which under a full API outage is what would carry the
# run past the DAG timeout instead of into a clean abort. Each worker's stderr
# goes to $WORK_DIR/<chunk>.log and is replayed by the parent when the slot is
# reaped: one contiguous block per chunk (retry lines, then the outcome)
# rather than interleaved lines, and the parent is the only writer. Failure
# accounting stays in the parent, keyed on the validated items file — exactly
# what merge consumes, so the coverage gate and the merge agree by
# construction and no worker state has to cross the fork.
extraction_prompt=$(cat "$SCRIPT_DIR/tech-news/extraction-prompt.md")
extraction_schema=$(cat "$SCRIPT_DIR/tech-news/extraction-schema.json")
extract_chunk() {   # one chunk, all attempts; backgrounded by the loop below
  local chunk="$1" name attempt rc
  name=$(basename "$chunk" .json)
  for attempt in 1 2 3; do
    run_claude_json "$EXTRACT_MODEL" "$extraction_schema" \
        "$extraction_prompt"$'\n'"$(cat "$chunk")" \
        > "$WORK_DIR/$name.envelope.json"
    rc=$?
    if (( rc != 0 )); then
      echo "$name: transport failure after internal retries (rc=$rc)" >&2
      return
    fi
    "$PYTHON3" "$PIPELINE" extract-validate --chunk "$chunk" \
         --envelope "$WORK_DIR/$name.envelope.json" \
         --output "$WORK_DIR/items/$name.json" && return
    echo "$name: invalid response (attempt $attempt/3)" >&2
  done
}
reap_slot() {   # replay slot $1's worker log, then account for its outcome
  local i="$1" name="${names[$1]}" n
  wait "${pids[i]}"
  cat "$WORK_DIR/$name.log" >&2
  if [[ ! -s "$WORK_DIR/items/$name.json" ]]; then
    n=$(jq length "$WORK_DIR/chunks/$name.json")
    echo "$name: failed — its $n messages count as unextracted" >&2
    failed_msgs=$((failed_msgs + n))
  fi
  pids[i]=""
}
# Tear down every live worker and reap it. Each worker leads its own process
# group (set -m below), so everything it forks is in that group — except the
# claude call: gtimeout puts itself and claude in a group of its OWN (that is
# how it reaps node's children on expiry), which is why a `dagu stop` on 09-03
# left one running past the script (GOTCHAS). So: STOP the worker's group — a
# frozen group cannot fork, so nothing can slip past the enumeration — TERM
# every child of its members by pid (that reaches the gtimeouts, which
# forward the TERM to their own group; node has no ignored signals, nothing
# on the exec path sets any), then KILL the group and reap. Reaping keeps the
# accounting and the log replay complete for the gate message.
kill_workers() {
  local i p kid
  for ((i = 0; i < EXTRACT_WIDTH; i++)); do
    [[ -n "${pids[i]:-}" ]] || continue
    kill -STOP -- "-${pids[i]}" 2>/dev/null
    for p in $(pgrep -g "${pids[i]}"); do
      for kid in $(pgrep -P "$p"); do kill -TERM "$kid" 2>/dev/null; done
    done
    kill -KILL -- "-${pids[i]}" 2>/dev/null
  done
  for ((i = 0; i < EXTRACT_WIDTH; i++)); do
    [[ -n "${pids[i]:-}" ]] && reap_slot "$i"
  done
}
# From here the lock must outlive the workers: releasing it while calls still
# ran would let the next run start on top of them. Job control makes each
# backgrounded worker a process-group leader — the handle kill_workers needs —
# and keeps a TERM aimed at this script's group (a `dagu stop`) off the
# workers, so the teardown always runs from here first.
trap 'kill_workers; rm -rf "$LOCK_DIR"' EXIT
set -m
saved_timeout=$CLAUDE_TIMEOUT
CLAUDE_TIMEOUT=600
failed_msgs=0
chunks=("$WORK_DIR"/chunks/chunk-*.json)
next=0
echo "=== Extracting ==="
while :; do
  (( failed_msgs * 10 > count )) && { kill_workers; break; }   # gate already lost
  live=0
  for ((slot = 0; slot < EXTRACT_WIDTH; slot++)); do
    if [[ -n "${pids[slot]:-}" ]]; then
      kill -0 "${pids[slot]}" 2>/dev/null && { live=1; continue; }
      reap_slot "$slot"
    fi
    (( next < ${#chunks[@]} && failed_msgs * 10 <= count )) || continue
    name=$(basename "${chunks[next]}" .json)
    extract_chunk "${chunks[next]}" 2> "$WORK_DIR/$name.log" &
    pids[slot]=$!; names[slot]=$name; live=1; next=$((next + 1))
  done
  (( live )) || break
  sleep 5
done
set +m
CLAUDE_TIMEOUT=$saved_timeout

# 4. Coverage gate, script-computed, before any network or ranking work: a
# failed chunk counts all its messages as unextracted; more than 10% missing
# means the digest would silently under-read the week — abort, send nothing,
# fail into the autofix path.
if (( failed_msgs * 10 > count )); then
  echo "coverage gate: $failed_msgs of $count messages unextracted (>10%) — aborting" >&2
  exit 1
fi
echo "coverage: $((count - failed_msgs))/$count messages extracted" >&2

# 5+6. Canonicalise links (resolve tracking wrappers, strip utm_*/ref/click
# ids; failures keep the wrapped URL, linkless items get the Gmail deep-link)
# and merge exact duplicates (same canonical URL) in code. Judgment
# clustering stays in the ranking call.
"$PYTHON3" "$PIPELINE" merge --items-dir "$WORK_DIR/items" \
    --data "$DATA_FILE" --output "$WORK_DIR/merged.json" || {
  echo "merge failed" >&2; exit 1;
}

# 7. Ranking: ONE opus call over the compact non-skip item list ({id, title,
# tldr, source, band} — no bodies). Same retry split as extraction: a
# transport failure surviving run_claude_json's internal retries aborts
# outright; only invalid responses consume this loop's attempts. Final
# failure aborts the send. Schema-valid ranking output is the send gate — it
# replaces the old grep-for-<li>/Footnote sanity checks. 900s cap: far
# smaller job than the old whole-corpus render's 1500s.
ranking_prompt=$(cat "$SCRIPT_DIR/tech-news/ranking-prompt.md")
ranking_schema=$(cat "$SCRIPT_DIR/tech-news/ranking-schema.json")
candidates=$("$PYTHON3" "$PIPELINE" ranking-input --merged "$WORK_DIR/merged.json") || {
  echo "ranking-input failed" >&2; exit 1;
}
CLAUDE_TIMEOUT=900
echo "=== Ranking ==="
ok=0
for attempt in 1 2 3; do
  run_claude_json "$RANK_MODEL" "$ranking_schema" \
      "$ranking_prompt"$'\n'"$candidates" > "$WORK_DIR/ranking.envelope.json"
  rc=$?
  if (( rc != 0 )); then
    echo "ranking: transport failure after internal retries (rc=$rc)" >&2
    break
  fi
  if "$PYTHON3" "$PIPELINE" rank-validate --merged "$WORK_DIR/merged.json" \
       --envelope "$WORK_DIR/ranking.envelope.json" \
       --output "$WORK_DIR/ranking.json"; then
    ok=1; break
  fi
  echo "ranking: invalid response (attempt $attempt/3)" >&2
done
(( ok )) || { echo "ranking failed after 3 attempts — nothing sent" >&2; exit 1; }
CLAUDE_TIMEOUT=$saved_timeout

# 8. Render the HTML template in code — the model emits no HTML; titles,
# tldrs, and urls resolve from the extracted items, footnote counts are
# script-computed.
"$PYTHON3" "$PIPELINE" render --merged "$WORK_DIR/merged.json" \
    --ranking "$WORK_DIR/ranking.json" --fetched "$count" --date "$DATE" \
    --output "$HTML_FILE" || { echo "render failed" >&2; exit 1; }
[[ -s "$HTML_FILE" ]] || { echo "$HTML_FILE missing or empty — skipping send" >&2; exit 1; }

# 9. Send
echo "=== Sending ==="
"$GWS" gmail +send \
    --to "$NOTIFY_EMAIL" \
    --subject "[Tech-news digest] Week ending $DATE" \
    --body "$(cat "$HTML_FILE")" \
    --html
