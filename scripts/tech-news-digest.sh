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
# bypasses it. Two runs share the fixed /tmp paths below, and the `rm -rf
# "$WORK_DIR"` further down deletes the other's state mid-flight. Seen
# 2026-08-20: the losing run died on a missing merged.json, then validated its
# scoring against a swapped candidate set ("unknown candidate id"), burned three
# attempts, sent nothing, and escalated to autofix. mkdir is atomic; the pid
# file lets a run that was SIGKILLed (DAG timeout — no EXIT trap) be cleaned up
# rather than blocking every future run. Exit 0, not 1: a skipped duplicate is
# not a failure and must not trigger the autofix handler.
LOCK_DIR="/tmp/tech-news-digest.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  holder=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
  if [[ -n "$holder" ]] && kill -0 "$holder" 2>/dev/null; then
    echo "another tech-news-digest run (pid $holder) is in flight — skipping" >&2
    exit 0
  fi
  echo "clearing stale tech-news-digest lock (pid ${holder:-unknown})" >&2
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR" || { echo "cannot acquire tech-news-digest lock" >&2; exit 1; }
fi
echo $$ > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR"' EXIT

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
DATA_FILE="/tmp/tech-news-data.json"
WORK_DIR="/tmp/tech-news-work"
HTML_FILE="/tmp/tech-news.html"
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

# Body-character budget per extraction chunk. THE runtime lever: smaller
# chunks mean more (but faster, more reliable) haiku calls; the whole run must
# stay inside the DAG's 5400s timeout. Must also stay well under ARG_MAX
# (~1MB) — the chunk JSON travels inline in the prompt argument, since the
# extraction calls run tool-less and cannot read files.
CHUNK_BUDGET="${TECH_NEWS_CHUNK_BUDGET:-80000}"

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
# validated items, merged list, ranking) for post-mortems; it is rebuilt per
# run so nothing stale leaks across weeks.
rm -rf "$WORK_DIR"
rm -f "$HTML_FILE"
mkdir -p "$WORK_DIR/chunks" "$WORK_DIR/items"
"$PYTHON3" "$PIPELINE" chunk --input "$DATA_FILE" \
    --outdir "$WORK_DIR/chunks" --budget "$CHUNK_BUDGET" || {
  echo "chunking failed" >&2; exit 1;
}

# 3. Extraction: one haiku call per chunk against the extraction schema,
# sequential (each claude process is heavy; bounded runtime and readable logs
# beat parallelism). Two retry layers, deliberately distinct: run_claude_json
# retries TRANSPORT faults (API blips, hangs) internally — a chunk it still
# fails on is failed outright, never re-retried here; this loop's attempts
# are consumed only by semantically INVALID responses (structured_output
# null, alien message ids), twice, then the chunk is marked failed and the
# run carries on. The per-attempt cap drops to 300s for this phase only —
# haiku on a <=80k-char prompt finishes in minutes, and the default 1500s
# would let one rare hang eat the DAG window multiplied across dozens of
# calls.
extraction_prompt=$(cat "$SCRIPT_DIR/tech-news/extraction-prompt.md")
extraction_schema=$(cat "$SCRIPT_DIR/tech-news/extraction-schema.json")
saved_timeout=$CLAUDE_TIMEOUT
CLAUDE_TIMEOUT=300
failed_msgs=0
echo "=== Extracting ==="
for chunk in "$WORK_DIR"/chunks/chunk-*.json; do
  name=$(basename "$chunk" .json)
  ok=0
  for attempt in 1 2 3; do
    run_claude_json "$EXTRACT_MODEL" "$extraction_schema" \
        "$extraction_prompt"$'\n'"$(cat "$chunk")" \
        > "$WORK_DIR/$name.envelope.json"
    rc=$?
    if (( rc != 0 )); then
      echo "$name: transport failure after internal retries (rc=$rc)" >&2
      break
    fi
    if "$PYTHON3" "$PIPELINE" extract-validate --chunk "$chunk" \
         --envelope "$WORK_DIR/$name.envelope.json" \
         --output "$WORK_DIR/items/$name.json"; then
      ok=1; break
    fi
    echo "$name: invalid response (attempt $attempt/3)" >&2
  done
  if (( ! ok )); then
    n=$(jq length "$chunk")
    echo "$name: failed after 3 attempts — its $n messages count as unextracted" >&2
    failed_msgs=$((failed_msgs + n))
  fi
done
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
