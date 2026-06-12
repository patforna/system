#!/usr/bin/env bash
set -uo pipefail

# Weekly jobs digest. Vets last 7 days of label:jobs mail against Patric's
# target-role criteria, validates top candidates via WebFetch, sends an HTML
# email to NOTIFY_EMAIL with vetted / borderline / rejected buckets.
# Designed to run via dagu (see dagu/jobs-digest.yaml).
#
# claude -p renders the HTML and subject to /tmp/jobs-digest.{html,subject};
# this script then sends. Keeping the +send out of the model loop avoids alias /
# PATH surprises in the Bash tool's shell (e.g. zsh `alias cat='bat'` silently
# emptying --body).

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/dagu-common.sh"
require_notify_email

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
DATA_FILE="/tmp/jobs-digest-data.json"
HTML_FILE="/tmp/jobs-digest.html"
SUBJECT_FILE="/tmp/jobs-digest.subject"
DATE=$(date '+%Y-%m-%d')

# 1. Fetch 7 days of jobs-labelled mail
"$PYTHON3" "$SCRIPT_DIR/lib/fetch-gmail-label.py" \
    --days 7 --label jobs --output "$DATA_FILE" || {
  echo "fetch failed" >&2; exit 1;
}

# A genuinely quiet week is possible (~18 msgs is the norm), but zero means
# the Gmail filter or label broke — fail into the autofix path rather than
# email a hollow digest.
count=$(jq length "$DATA_FILE")
if (( count == 0 )); then
  echo "0 messages fetched — jobs filter/label likely broken" >&2
  exit 1
fi

# 2. Vet, validate, compose
PROMPT_FILE="$SCRIPT_DIR/jobs-digest/prompt.md"
[[ -f "$PROMPT_FILE" ]] || { echo "missing $PROMPT_FILE" >&2; exit 1; }

rm -f "$HTML_FILE" "$SUBJECT_FILE"

prompt=$(sed -e "s|{DATA_FILE}|$DATA_FILE|g" \
             -e "s|{DATE}|$DATE|g" "$PROMPT_FILE")

echo "=== Rendering jobs digest ==="
run_claude "$prompt" 2>&1 | tee /tmp/jobs-digest.log

if [[ ! -s "$HTML_FILE" ]]; then
  echo "jobs digest: $HTML_FILE missing or empty — not sending" >&2
  exit 1
fi

# Non-empty isn't enough: a refusal, apology, or fenced-markdown render would
# otherwise be emailed as-is. Require the bucket headings and the footnote.
if ! grep -qi "<h2" "$HTML_FILE" || ! grep -qi "footnote" "$HTML_FILE"; then
  echo "jobs digest: HTML fails sanity check (no <h2>/Footnote) — not sending" >&2
  exit 1
fi

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
