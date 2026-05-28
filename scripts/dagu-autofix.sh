#!/usr/bin/env bash
set -uo pipefail

# Autofix handler for failed dagu DAG runs. Wired in via handler_on.failure
# in base.yaml. Reads DAG_NAME, DAG_RUN_ID, DAG_RUN_LOG_FILE from the dagu
# runtime env, hands the failure to a local Claude Code session, and lets it
# decide whether to fix-and-commit, treat as transient, or escalate via email.
#
# Outcomes are appended to $STATE_FILE (one JSON line each) so the daily
# digest can join failures against autofix actions.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/dagu-common.sh"

DAG_NAME="${DAG_NAME:-unknown}"
DAG_RUN_ID="${DAG_RUN_ID:-unknown}"
LOG_FILE="${DAG_RUN_LOG_FILE:-}"

STATE_DIR="${HOME}/.local/state"
STATE_FILE="${STATE_DIR}/dagu-autofix.jsonl"
mkdir -p "$STATE_DIR"

# Per-DAG sentinel holding the run-id of an autofix-triggered retry. Used as
# a loop guard: if that exact run fails again, we escalate instead of
# fixing-and-retrying a second time.
RETRY_DIR="${STATE_DIR}/dagu-autofix-retry"
RETRY_SENTINEL="${RETRY_DIR}/${DAG_NAME}"
mkdir -p "$RETRY_DIR"

DAGU="${DAGU:-/opt/homebrew/bin/dagu}"

LOG_TAIL=""
RETRY_COUNT=0
if [[ -n "$LOG_FILE" && -r "$LOG_FILE" ]]; then
  LOG_TAIL=$(tail -100 "$LOG_FILE" 2>/dev/null || true)
  # Count retries that fired and still failed. Each "Step execution failed;
  # retrying" line in dagu's run log = one retry attempt. Dagu only invokes
  # this handler after the configured retry_policy is exhausted, so RETRY_COUNT
  # >= 1 means "retries were configured AND all failed on the same step" — the
  # 'transient' hypothesis has already been tested and disproved.
  RETRY_COUNT=$(grep -c 'Step execution failed; retrying' "$LOG_FILE" 2>/dev/null || echo 0)
fi

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TODAY=$(date +%Y-%m-%d)

# Loop guard. If this failed run is itself the run we re-triggered after a
# previous autofix, the committed fix did not hold. Don't fix-and-retry
# again (that risks an endless fail→fix→retry loop) — escalate to Patric.
if [[ -f "$RETRY_SENTINEL" ]]; then
  sentinel_runid=$(head -1 "$RETRY_SENTINEL" 2>/dev/null || true)
  sentinel_age=$(( $(date +%s) - $(stat -f %m "$RETRY_SENTINEL" 2>/dev/null || echo 0) ))
  if [[ "$sentinel_runid" == "$DAG_RUN_ID" ]]; then
    rm -f "$RETRY_SENTINEL"
    if [[ -n "$NOTIFY_EMAIL" ]]; then
      /opt/homebrew/bin/gws gmail +send --to "$NOTIFY_EMAIL" \
        --subject "[DAGU AUTOFIX] $DAG_NAME — re-run after fix still failing" \
        --body "Autofix committed a fix for $DAG_NAME and re-triggered it, but the re-run ($DAG_RUN_ID) also failed. The fix did not hold — needs manual investigation. Log: ${LOG_FILE:-(unavailable)}" >/dev/null 2>&1 || true
    fi
    echo "{\"ts\":\"$TS\",\"dag\":\"$DAG_NAME\",\"run_id\":\"$DAG_RUN_ID\",\"outcome\":\"escalated\",\"note\":\"escalated: autofix re-run also failed, fix did not hold, needs human\"}" >> "$STATE_FILE"
    exit 0
  fi
  # Sentinel left over from an old, unrelated incident — clear and proceed.
  if (( sentinel_age > 86400 )); then rm -f "$RETRY_SENTINEL"; fi
fi

# Bail out cleanly if claude isn't available — log and exit so we don't lose
# the failure entirely.
if [[ ! -x "$CLAUDE" ]]; then
  record_fallback "$STATE_FILE" "$DAG_NAME" "$DAG_RUN_ID" "$TS" unhandled "claude binary not found at $CLAUDE"
  exit 0
fi

# Use `read -d ''` rather than `PROMPT=$(cat <<EOF ... EOF)` because bash
# tracks single quotes inside `$(...)` even when they sit inside an unquoted
# heredoc — a lone apostrophe (e.g. "Patric's") would break the parse.
IFS='' read -r -d '' PROMPT <<EOF || true
You are the autofix handler for a failed dagu DAG run on Patric Mac. Today is $TODAY.

# Context
- DAG: $DAG_NAME
- Run ID: $DAG_RUN_ID
- Log file: ${LOG_FILE:-(unavailable)}
- DAG yaml: \$HOME/github/system/dagu/$DAG_NAME.yaml
- Repo root for most fixes: \$HOME/github/system
- Retries that fired and still failed: $RETRY_COUNT (dagu only calls this handler after the configured retry_policy is burned)

# Last 100 lines of log

${LOG_TAIL:-(no log content)}

# End of log

# Your job

1. Investigate the root cause. Read the full log if needed, the DAG yaml, and any scripts it invokes.
2. Classify the failure as one of:
   - transient: a one-off failure on a step with NO retry_policy, where the error pattern is a clear single blip (one timeout, one 5xx, one rate-limit hit) and "next scheduled run will pass" is a credible claim.
   - fixable: bug, drift, or config issue you can correct in local code.
   - escalated: requires credentials, secrets, OAuth re-auth, external account access, or — importantly — a persistent external dependency that local code can't fix (e.g. an upstream API repeatedly timing out after the configured retries already burned through).

   Before you may choose 'transient', run this accountability check:
   - A failure that reaches this handler has already exhausted its configured retry_policy
     — dagu does not invoke on_failure until retries are burned. Retries fired and failed
     for this run: $RETRY_COUNT.
   - If RETRY_COUNT >= 1, retries were configured and all failed on the same step.
     'transient' hypothesises "the next run will pass" — those retries already tested
     and disproved that hypothesis with 5+ minute gaps between attempts. Do NOT call it
     transient. Pick 'fixable' (correct it in code — e.g. longer backoff, fallback source,
     wider timeout in the calling pipeline) or 'escalated' (Patric's call; common when an
     external API is persistently degraded and the right response is human judgement, not
     another patch). If you escalate, your email body must say what the retry exhaustion
     tells you (e.g. "3 attempts over 4h all hit the same nasdaq.com read timeout — not a
     blip; either harden the Load step or wait it out").
   - 'transient' is only acceptable when RETRY_COUNT == 0.

   Before you may choose 'fixable', run this accountability check:
   - The signal that matters is whether THIS SAME failure has been fixed
     before and come back — not how many unrelated things this DAG has fixed.
     A broad check like drift-check legitimately catches different items over
     time; each is independent. Read this DAG's prior 'fixed' notes:
       jq -r --arg d "$DAG_NAME" 'select(.dag==\$d and .outcome=="fixed")|.note' $STATE_FILE | tail -20
     Compare them to the failure in front of you. If the SAME root cause (same
     drift item, same error) has been fixed 2+ times and is failing again, the
     fix is not holding — do NOT patch it again. Classify 'escalated' (a fix
     that keeps not working is a human's call, not another patch). Unrelated
     prior fixes do not count toward this.
   - Read \$HOME/github/system/private/GOTCHAS.md. If your intended fix
     repeats a hypothesis already recorded there with "No" under "Did it
     work?", do NOT try it again — classify 'escalated'.
3. Act on the classification:
   - transient: do nothing. Next scheduled run will pass.
   - fixable: fix the code in the relevant repo (usually \$HOME/github/system), commit to main with a clear, brief message that explains the failure and the fix. Push. Do NOT open a PR or GitHub issue — Patric explicitly does not want that noise. Then append a row to \$HOME/github/system/private/GOTCHAS.md under the matching problem section (its header explains the one-line format): what happened, what you tried & why (your hypothesis), and "Not proven" under "Did it work?". Create a new section if none fits. Append only — never edit or delete an existing row.
   - escalated: send Patric a focused email with diagnosis and the specific thing you need from him. Use the gws gmail +send command with the recipient \$NOTIFY_EMAIL (value: $NOTIFY_EMAIL), subject "[DAGU AUTOFIX] $DAG_NAME — needs human", and a brief body containing your diagnosis and the ask.

# Recording your outcome (mandatory)

Before you finish, append exactly one JSON line to $STATE_FILE. Use bash with single quotes around the JSON, then a redirect:

  echo JSON >> $STATE_FILE

Where JSON is a one-line object with fields: ts ($TS), dag ($DAG_NAME), run_id ($DAG_RUN_ID), outcome (one of transient/fixed/escalated), note, commit (sha if you committed, empty otherwise).

The note field is shown verbatim in Patric's daily digest as the only context for what happened. Format it as one short sentence (≤120 chars) of the form "<verb>: <what>" so it reads well alongside other rows. Examples:
  - "fixed: removed stray prose from DAG command (parsed as 4 positional args)"
  - "transient: single 503 from sheets API (step has no retry_policy)"
  - "escalated: 3 attempts over 4h all hit nasdaq.com read timeout on Load — persistent upstream, not a blip"
  - "escalated: gmail OAuth token expired, needs re-auth via gws auth"

The next daily digest reads this file to surface autofix outcomes. If you skip this, the digest will treat the failure as unhandled and bug Patric to investigate.

# Notes
- You have file system access, gws gmail, msgvault, gh, dagu CLI, and your usual skills.
- British spelling and metric units in any commit message or email.
- Be brief. No fluff. No AI slop.
- The only hard escalation rule is the credential one. Otherwise, use judgement.
- If you cannot fit the work into your session for any reason, escalate rather than leaving the state file empty.
EOF

LOG_OUT="/tmp/dagu-autofix-${DAG_NAME}.log"

{
  echo "=== dagu-autofix $TS — $DAG_NAME ($DAG_RUN_ID) ==="
  run_claude "$PROMPT" 2>&1
  rc=$?
  echo "=== claude exit: $rc ==="
} | tee "$LOG_OUT"

# If Claude exited non-zero AND no state line was written for this run, log a
# fallback entry so the digest sees something.
record_fallback "$STATE_FILE" "$DAG_NAME" "$DAG_RUN_ID" "$TS" unhandled "autofix session ended without recording outcome"

# If autofix actually fixed the failure, re-trigger the DAG so the recovered
# run produces its output this cycle — otherwise a weekly digest (etc.) stays
# missed until its next scheduled run despite the fix being committed.
#
# Enqueue (not start): the failing run is still active while this handler
# runs, so a direct start would be dropped by overlap_policy=skip. The
# enqueued run waits in the queue and fires once the DAG is idle.
#
# One retry only. The new run gets a known run-id recorded in the sentinel;
# if it also fails, the loop guard at the top escalates instead of looping.
outcome=$(jq -r --arg rid "$DAG_RUN_ID" \
  'select(.run_id==$rid)|.outcome' "$STATE_FILE" 2>/dev/null | tail -1)
if [[ "$outcome" == "fixed" ]]; then
  retry_runid=$(uuidgen | tr 'A-Z' 'a-z')
  printf '%s\n' "$retry_runid" > "$RETRY_SENTINEL"
  if "$DAGU" enqueue --trigger-type retry -r "$retry_runid" "$DAG_NAME" \
       >/dev/null 2>&1; then
    echo "{\"ts\":\"$TS\",\"dag\":\"$DAG_NAME\",\"run_id\":\"$retry_runid\",\"parent_run_id\":\"$DAG_RUN_ID\",\"outcome\":\"retriggered\",\"note\":\"retriggered: re-ran $DAG_NAME after autofix fix\"}" >> "$STATE_FILE"
    echo "=== autofix re-triggered $DAG_NAME as $retry_runid ===" | tee -a "$LOG_OUT"
  else
    rm -f "$RETRY_SENTINEL"
    echo "=== autofix re-trigger enqueue FAILED for $DAG_NAME ===" | tee -a "$LOG_OUT"
  fi
fi

exit 0
