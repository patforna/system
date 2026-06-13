#!/usr/bin/env bash
set -uo pipefail

# Weekly tech-news digest. Sends an HN-style ranked email to NOTIFY_EMAIL by
# feeding 7 days of label:tech-news mail through claude -p.
# Designed to run via dagu (see dagu/tech-news-digest.yaml).
#
# claude -p renders the HTML to /tmp/tech-news.html; this script then sends.
# Keeping the +send out of the model loop avoids alias / PATH surprises in the
# Bash tool's shell (e.g. zsh `alias cat='bat'` silently emptying --body).

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/dagu-common.sh"
require_notify_email

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
DATA_FILE="/tmp/tech-news-data.json"
PROMPT_FILE="$SCRIPT_DIR/tech-news/prompt.md"
HTML_FILE="/tmp/tech-news.html"
DATE=$(date '+%Y-%m-%d')

# 1. Fetch 7 days of tech-news mail
"$PYTHON3" "$SCRIPT_DIR/lib/fetch-gmail-label.py" \
    --days 7 --label tech-news --output "$DATA_FILE" || {
  echo "fetch failed" >&2; exit 1;
}

# A healthy week is ~90-120 messages; near-zero means the Gmail filter or
# label broke (see scripts/tech-news/senders.txt), not a quiet week — fail
# into the autofix path rather than email a hollow digest.
count=$(jq length "$DATA_FILE")
if (( count < 30 )); then
  echo "only $count messages fetched (norm ~100) — tech-news filter/label likely broken" >&2
  exit 1
fi

# 2. Render
[[ -f "$PROMPT_FILE" ]] || { echo "missing $PROMPT_FILE" >&2; exit 1; }
rm -f "$HTML_FILE"

prompt=$(sed -e "s|{DATA_FILE}|$DATA_FILE|g" \
             -e "s|{DATE}|$DATE|g" "$PROMPT_FILE")

echo "=== Rendering ==="
run_claude "$prompt" 2>&1 | tee /tmp/tech-news.log

if [[ ! -s "$HTML_FILE" ]]; then
  echo "$HTML_FILE missing or empty — skipping send" >&2
  exit 1
fi

# Non-empty isn't enough: a refusal, apology, or fenced-markdown render would
# otherwise be emailed as-is. Require the ranked list and the footnote.
if ! grep -qi "<li" "$HTML_FILE" || ! grep -qi "footnote" "$HTML_FILE"; then
  echo "rendered HTML fails sanity check (no <li>/Footnote) — skipping send" >&2
  exit 1
fi

# Coverage observability (soft — never blocks send). The prompt asks the model
# to record how many of the fetched messages it actually processed. A healthy
# run reads all of them; a number well below $count means the ranking saw only
# part of the week. Logged, not enforced — a count quibble shouldn't lose a
# real digest, but it surfaces in the dagu logs if coverage degrades.
processed=$(grep -oiE 'coverage: processed=[0-9]+' "$HTML_FILE" | grep -oE '[0-9]+' | head -1)
if [[ -n "$processed" ]]; then
  echo "coverage: model processed $processed of $count fetched messages" >&2
  (( processed < count )) && echo "WARN: incomplete coverage ($processed/$count)" >&2
else
  echo "WARN: no coverage marker in render" >&2
fi

# 3. Send
echo "=== Sending ==="
"$GWS" gmail +send \
    --to "$NOTIFY_EMAIL" \
    --subject "[Tech-news digest] Week ending $DATE" \
    --body "$(cat "$HTML_FILE")" \
    --html
