#!/usr/bin/env bash
set -uo pipefail

# Jobs digest, twice weekly. Vets last 4 days of label:jobs mail against Patric's
# target-role criteria and emails a vetted / borderline / rejected shortlist to
# NOTIFY_EMAIL. Designed to run via dagu (see dagu/jobs-digest.yaml).
#
# The script owns the pipeline; claude only does judgment. Phases: chunked
# structured extraction (haiku, tool-less), a script-computed coverage gate,
# code-side exact-duplicate merge and mechanical hard-filters (EM/management
# titles, sub-floor base comp), ONE agentic scoring call (opus, WebFetch allowed
# to verify top candidates) returning schema-bound JSON, and a code-rendered
# three-bucket HTML email. The model never emits HTML or self-reports counts —
# which removes the old prompt-orchestrated subagent fan-out, model-written HTML
# behind grep gates, and self-reported figures. See
# private/scripts/jobs-digest/pipeline.py.
#
# Keeping +send out of the model loop avoids alias / PATH surprises in the Bash
# tool's shell (e.g. zsh `alias cat='bat'` silently emptying --body).

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/dagu-common.sh"
require_notify_email

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# Prompts, schemas, and the pipeline module live under private/ (git-crypt):
# they encode personal role/comp criteria that must not sit plaintext in a
# public repo.
JOBS_DIR="$SCRIPT_DIR/../private/scripts/jobs-digest"
PIPELINE="$JOBS_DIR/pipeline.py"
# Scratch paths are per-run, keyed on the dagu run id (PID fallback for a manual
# `bash` run). The old fixed /tmp locations were shared across every instance, so
# a second run's startup `rm -rf` wiped an in-flight run's intermediates
# mid-scoring — merged.json vanished (FileNotFoundError), then reappeared with a
# different candidate set ("unknown candidate id"). The reconciler serialises its
# OWN runs, but nothing stops an out-of-band (manual / retrigger) run overlapping,
# so isolate by run rather than assume single-flight. See private/GOTCHAS.md.
RUN_TAG="${DAG_RUN_ID:-manual-$$}"
DATA_FILE="/tmp/jobs-digest-data-${RUN_TAG}.json"
WORK_DIR="/tmp/jobs-digest-work-${RUN_TAG}"
HTML_FILE="/tmp/jobs-digest-${RUN_TAG}.html"
SUBJECT_FILE="/tmp/jobs-digest-${RUN_TAG}.subject"
DATE=$(date '+%Y-%m-%d')

EXTRACT_MODEL="claude-haiku-4-5-20251001"
SCORE_MODEL="claude-opus-4-8"

# The prompt/schema files are cat'd unchecked below — fail fast before any fetch
# or extraction rather than feed claude an empty prompt.
[[ -f "$PIPELINE" ]] || { echo "missing $PIPELINE" >&2; exit 1; }
for f in extraction-prompt.md extraction-schema.json \
         scoring-prompt.md scoring-schema.json; do
  [[ -s "$JOBS_DIR/$f" ]] || { echo "$f missing or empty" >&2; exit 1; }
done

# Body-character budget per extraction chunk. Sized against extraction OUTPUT,
# not input: ARG_MAX (~1MB) has huge headroom, but a listings-dense chunk emits
# roughly its own weight in structured roles, and generating that JSON is what
# burns the per-attempt clock. 07-20 measured it — an 84k-char chunk timed out at
# 300s three times while an 11k-char one returned 44 roles (33k envelope) well
# inside the cap. 20k keeps each call near twice that proven-good size.
CHUNK_BUDGET="${JOBS_CHUNK_BUDGET:-20000}"

# 1. Fetch the trailing window of jobs-labelled mail (gws fetcher, count==0
# guard). --days must stay matched to the DAG's SLO in scripts/dagu-jobs.conf.
# --exclude-subject drops this digest's own past emails: they carry label:jobs,
# run 80k+ chars, blow the chunk budget, and can only re-extract last week.
"$PYTHON3" "$SCRIPT_DIR/lib/fetch-gmail-label.py" \
    --days 4 --label jobs --exclude-subject "Jobs digest" \
    --output "$DATA_FILE" || {
  echo "fetch failed" >&2; exit 1;
}

# A genuinely quiet week is possible (~18 msgs is the norm), but zero means the
# Gmail filter or label broke — fail into the autofix path rather than email a
# hollow digest.
count=$(jq length "$DATA_FILE")
if (( count == 0 )); then
  echo "0 messages fetched — jobs filter/label likely broken" >&2
  exit 1
fi

# 2. Chunk. WORK_DIR keeps every intermediate (chunks, envelopes, validated
# roles, merged list, scoring) for post-mortems. The dir is per-run and unique by
# construction, so nothing stale can leak in; sweep siblings older than 2 days so
# per-run dirs don't accumulate in /tmp (the +2 age can't touch a live run).
find /tmp -maxdepth 1 -name 'jobs-digest-work-*' -type d -mtime +2 -exec rm -rf {} + 2>/dev/null || true
find /tmp -maxdepth 1 -type f \( -name 'jobs-digest-data-*.json' -o -name 'jobs-digest-*.html' -o -name 'jobs-digest-*.subject' \) -mtime +2 -delete 2>/dev/null || true
rm -rf "$WORK_DIR"
rm -f "$HTML_FILE" "$SUBJECT_FILE"
mkdir -p "$WORK_DIR/chunks" "$WORK_DIR/items"
"$PYTHON3" "$PIPELINE" chunk --input "$DATA_FILE" \
    --outdir "$WORK_DIR/chunks" --budget "$CHUNK_BUDGET" || {
  echo "chunking failed" >&2; exit 1;
}

# 3. Extraction: one haiku call per chunk against the extraction schema,
# tool-less, sequential. Two retry layers, deliberately distinct:
# run_claude_json retries TRANSPORT faults (API blips, hangs) internally — a
# chunk it still fails on is failed outright; this loop's attempts are consumed
# only by semantically INVALID responses (structured_output null, alien message
# ids, empty from a multi-message chunk), twice, then the chunk is marked failed
# and the run carries on. Per-attempt cap drops to 600s here — generous against a
# CHUNK_BUDGET-sized chunk (the 11k-char chunk that returned 44 roles on 07-20
# finished well inside half this), while still bounding a hung call.
extraction_prompt=$(cat "$JOBS_DIR/extraction-prompt.md")
extraction_schema=$(cat "$JOBS_DIR/extraction-schema.json")
saved_timeout=$CLAUDE_TIMEOUT
CLAUDE_TIMEOUT=600
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
    # Smaller chunks mean more of them, so a total API outage could otherwise
    # burn 3 capped attempts per chunk and overrun the DAG's 5400s timer (which
    # SIGKILLs mid-script — see GOTCHAS). Once enough messages are lost that the
    # coverage gate below can no longer pass, no remaining chunk can save the
    # run: stop and fail fast rather than keep paying for a doomed digest.
    if (( failed_msgs * 10 > count )); then
      echo "coverage already unrecoverable — abandoning remaining chunks" >&2
      break
    fi
  fi
done
CLAUDE_TIMEOUT=$saved_timeout

# 4. Coverage gate, script-computed, before scoring: a failed chunk counts all
# its messages as unextracted; more than 10% missing means the digest would
# silently under-read the week — abort, send nothing, fail into autofix.
if (( failed_msgs * 10 > count )); then
  echo "coverage gate: $failed_msgs of $count messages unextracted (>10%) — aborting" >&2
  exit 1
fi
echo "coverage: $((count - failed_msgs))/$count messages extracted" >&2

# 5+6. Merge exact duplicates (same posting_url, else same company + normalised
# title) and apply mechanical hard-filters (EM/management titles, stated base
# below the CHF floor) in code. Filtered-out roles are retained with a reason so
# the rejected bucket and footnote counts are script-computed. Judgment filters
# (tech-as-supporting-function, anti-domain) stay in the scoring call.
"$PYTHON3" "$PIPELINE" merge --items-dir "$WORK_DIR/items" \
    --data "$DATA_FILE" --output "$WORK_DIR/merged.json" || {
  echo "merge failed" >&2; exit 1;
}

# 7. Scoring: ONE agentic opus call over the survivor candidates. Unlike
# extraction it runs tools-ENABLED (WebFetch) so it can verify top candidates'
# title/level/comp/location/still-open before scoring; structured output still
# composes with the tool turns. Same retry split as extraction. Schema-valid
# scoring output is the send gate — it replaces the old grep-for-<h2>/Footnote
# checks. When nothing survives the hard-filters there is nothing to score —
# skip the call and render a rejected-only digest. 1200s cap gives WebFetch
# headroom while 3*1200 + 90s backoff stays inside the DAG's 5400s window.
candidates=$("$PYTHON3" "$PIPELINE" scoring-input --merged "$WORK_DIR/merged.json") || {
  echo "scoring-input failed" >&2; exit 1;
}
if [[ "$candidates" == "[]" ]]; then
  echo "no candidates survived hard-filters — rendering rejected-only digest" >&2
  echo '{"scored": []}' > "$WORK_DIR/scoring.json"
else
  scoring_prompt=$(cat "$JOBS_DIR/scoring-prompt.md")
  scoring_schema=$(cat "$JOBS_DIR/scoring-schema.json")
  CLAUDE_TIMEOUT=1200
  echo "=== Scoring ==="
  ok=0
  for attempt in 1 2 3; do
    run_claude_json "$SCORE_MODEL" "$scoring_schema" \
        "$scoring_prompt"$'\n'"$candidates" WebFetch \
        > "$WORK_DIR/scoring.envelope.json"
    rc=$?
    if (( rc != 0 )); then
      echo "scoring: transport failure after internal retries (rc=$rc)" >&2
      break
    fi
    if "$PYTHON3" "$PIPELINE" score-validate --merged "$WORK_DIR/merged.json" \
         --envelope "$WORK_DIR/scoring.envelope.json" \
         --output "$WORK_DIR/scoring.json"; then
      ok=1; break
    fi
    echo "scoring: invalid response (attempt $attempt/3)" >&2
  done
  (( ok )) || { echo "scoring failed after 3 attempts — nothing sent" >&2; exit 1; }
  CLAUDE_TIMEOUT=$saved_timeout
fi

# 8. Render the three-bucket HTML and the subject in code — the model emits no
# HTML; bucket counts and the footnote breakdown are script-computed.
"$PYTHON3" "$PIPELINE" render --merged "$WORK_DIR/merged.json" \
    --scoring "$WORK_DIR/scoring.json" --fetched "$count" --date "$DATE" \
    --output "$HTML_FILE" --subject-output "$SUBJECT_FILE" || {
  echo "render failed" >&2; exit 1;
}
[[ -s "$HTML_FILE" ]] || { echo "$HTML_FILE missing or empty — skipping send" >&2; exit 1; }

# 9. Send
if [[ -s "$SUBJECT_FILE" ]]; then
  SUBJECT=$(tr -d '\n' < "$SUBJECT_FILE")
else
  SUBJECT="[Jobs digest] Week ending $DATE"
fi

echo "=== Sending jobs digest ==="
"$GWS" gmail +send \
    --to "$NOTIFY_EMAIL" \
    --subject "$SUBJECT" \
    --body "$(cat "$HTML_FILE")" \
    --html
