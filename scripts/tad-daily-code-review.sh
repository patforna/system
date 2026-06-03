#!/usr/bin/env bash
set -uo pipefail

# TAD code-review sweep.
# =====================
# Scheduled local replacement for the retired .github/workflows/claude-code-review.yml.
#
# It is deliberately the COMPLEMENT of /auto-task, not a re-review: the only
# commits it looks at are the ones that reached main WITHOUT going through
# /auto-task (hand commits, hotfixes, pre-commit-hook-skipped commits, direct
# doc/config edits). Commits that carry the (task/NNN) convention already had
# the stronger ensemble review — re-reviewing them is net-negative self-review
# and pure fatigue, so they are excluded by construction.
#
# Overriding rule: review fatigue is the enemy. The default outcome is silence.
# Only a Critical/Major finding that cannot be safely auto-fixed ever reaches
# the human, as one focused email — the same escalation channel dagu-autofix.sh
# already uses. Trivial Minor/Nit findings are auto-fixed behind a check gate
# and shipped via a GitHub PR that the script auto-rebase-merges (branch then
# deleted); GitHub's built-in PR-merged emails are the audit surface. If the
# ship-out path fails (push/PR/merge), the branch stays standing as a fallback
# record and the run records `autofixed-merge-failed`. Everything else is dropped.
#
# Division of labour (deliberate):
#   - The Claude session ONLY reviews, applies trivial autofixes behind the
#     check gate, and writes ONE structured result file. It never sends mail,
#     never writes the JSONL, never touches the marker — because the fingerprint
#     is a sha1 (an LLM cannot compute that by hand), the marker decision is
#     coupled to send success, and the dedup window is exact date arithmetic.
#   - THIS SCRIPT owns every piece of durable state deterministically: it reads
#     the result file, computes the dedup fingerprint, runs the dedup gate,
#     sends the one email, writes the JSONL row, and advances the marker.
#
# State / sink reuse (no new sink, no new knob):
#   - marker: a local-only git tag `review-swept` in the TAD repo. It advances
#     after a run whose escalation was absent, delivered, muted, or suppressed —
#     but NOT when a required send failed (those retry next run). So a delivered
#     finding surfaces exactly once and never nags again.
#   - outcomes: appended to ~/.local/state/dagu-autofix.jsonl (a superset of the
#     schema the daily digest already understands), dag="tad-daily-code-review".
#     The digest reads this file only for *Failed* runs, and a sweep run that
#     escalates still exits Succeeded, so the extra fields have zero blast radius
#     and the digest keeps showing the sweep as OK.
#   - escalation (Critical/Major): one gws gmail +send to NOTIFY_EMAIL, exactly
#     like dagu-autofix.sh. NOTIFY_EMAIL unset = uniform mute (no send, no error).
#   - autofix ship-out (Minor/Nit): `gh pr create` then `gh pr merge --rebase
#     --delete-branch` against patforna/tad. GitHub's own PR-merged email is the
#     human-visible audit trail. Failure leaves the standing branch as today.
#
# A genuine sweep *failure* (worktree creation broken, claude binary missing,
# crash/timeout) is a normal DAG failure: exit non-zero so the inherited
# handler_on.failure (dagu-autofix.sh) + daily digest pick it up like every
# other DAG. The email path here is ONLY for a SUCCESSFUL sweep that found
# something a human must see — failing the DAG for a gmail hiccup would wake the
# (also gmail-dependent) autofix handler on the very thing we are trying to send.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/dagu-common.sh"

TAD="${TAD_REPO:-${HOME}/github/tad}"
MARKER_TAG="review-swept"
STALE_TAG="last-reviewed"          # left behind by the retired GitHub workflow
WT_ROOT="${HOME}/github/.worktrees/tad"

STATE_DIR="${HOME}/.local/state"
STATE_FILE="${STATE_DIR}/dagu-autofix.jsonl"
mkdir -p "$STATE_DIR"

# The autofix safety gate. `just check-all` mirrors CI (backend check +
# openapi-drift + frontend-check/e2e + workflow/md lint). The worktree needs
# its own frontend node_modules (prepared below) because they are not shared.
CHECK_CMD="${SWEEP_CHECK_CMD:-just check-all}"

DAG="tad-daily-code-review"
KIND="review_blocker"              # row type tag; a future kaizen pass uses kaizen_blocker
DAG_RUN_ID="${DAG_RUN_ID:-manual-$(date +%s)}"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TODAY=$(date +%Y-%m-%d)
RANGE=""                           # set once the review range is known

log() { echo "[tad-daily-code-review] $*"; }

# Append exactly one JSONL row in the digest-compatible superset schema.
emit_row() {
  local outcome="$1" fingerprint="$2" note="$3" commit="$4"
  jq -cn \
    --arg ts "$TS" --arg dag "$DAG" --arg run_id "$DAG_RUN_ID" \
    --arg outcome "$outcome" --arg kind "$KIND" \
    --arg fingerprint "$fingerprint" --arg range "$RANGE" \
    --arg note "$note" --arg commit "$commit" \
    '{ts:$ts,dag:$dag,run_id:$run_id,outcome:$outcome,kind:$kind,fingerprint:$fingerprint,range:$range,note:$note,commit:$commit}' \
    >> "$STATE_FILE"
}

advance_marker() { git -C "$TAD" tag -f "$MARKER_TAG" "$HEAD_SHA" >/dev/null; }

# True iff the autofix branch carries a commit beyond main HEAD (a retained fix).
branch_has_commits() {
  [[ "$(git -C "$TAD" rev-list --count "${HEAD_SHA}..refs/heads/${AUTOFIX_BRANCH}" 2>/dev/null || echo 0)" -gt 0 ]]
}

# True iff the PREVIOUS sweep run also ended `unhandled` for this exact range.
# Used to tolerate a one-off bad/incomplete result (exit 0, retry) but surface a
# PERSISTENT one (e.g. prompt/model drift) — two consecutive unhandled runs that
# make no forward progress should fail the DAG so the digest/handler see it,
# rather than silently re-reviewing the same range forever.
prev_unhandled_same_range() {
  local last
  last=$(jq -rc 'select(.dag=="tad-daily-code-review")' "$STATE_FILE" 2>/dev/null | tail -1)
  [[ -n "$last" ]] \
    && [[ "$(jq -r '.outcome' <<<"$last" 2>/dev/null)" == "unhandled" ]] \
    && [[ "$(jq -r '.range' <<<"$last" 2>/dev/null)" == "$RANGE" ]]
}

if [[ ! -d "$TAD/.git" ]]; then
  log "TAD repo not found at $TAD — nothing to do."
  exit 0
fi

HEAD_SHA=$(git -C "$TAD" rev-parse main 2>/dev/null) || {
  log "cannot resolve main in $TAD — nothing to do."; exit 0; }

# --- First-ever run: seed the marker, review nothing. -----------------------
# "Seed at deploy HEAD" — the first real review covers only commits made after
# the sweep was deployed, never the whole backlog.
if ! git -C "$TAD" rev-parse -q --verify "refs/tags/${MARKER_TAG}" >/dev/null 2>&1; then
  # Check the seed write: if it silently failed, every later run would re-take
  # this first-run branch and review nothing forever. Fail loudly instead so the
  # digest surfaces it (a repo where you cannot write a tag is genuinely broken).
  if ! git -C "$TAD" tag -f "$MARKER_TAG" "$HEAD_SHA" >/dev/null 2>&1; then
    log "ERROR: first run could not write marker tag ${MARKER_TAG} — failing the run so the digest surfaces it."
    exit 1
  fi
  # The retired workflow's tag is meaningless now; remove it once so it can't
  # be mistaken for the live marker.
  git -C "$TAD" tag -d "$STALE_TAG" >/dev/null 2>&1 || true
  log "first run — seeded ${MARKER_TAG} at ${HEAD_SHA:0:12}, no review."
  exit 0
fi

BASE=$(git -C "$TAD" rev-parse "refs/tags/${MARKER_TAG}")
if [[ "$BASE" == "$HEAD_SHA" ]]; then
  log "no new commits on main since last sweep — OK."
  exit 0
fi

# --- Compute the exclusion set: commits that BYPASSED /auto-task. -----------
# Reliable because ship-task merges with `git merge --ff-only` and never
# squashes (verified), so (task/NNN) subjects land on main intact.
#   exclude: subject carries (task/NNN[.NN]) -> went through the task workflow.
#   exclude: bot commits (Dependabot / github-actions) -> not a human bypass,
#            out of scope for a code-review sweep.
#   the sweep's own autofix commits live on a never-merged branch, so they
#   never appear in a main range — excluded by construction.
#   --no-merges: the single-parent commits a merge brings onto main are still
#   listed and reviewed; only a true merge commit's own conflict-resolution diff
#   is skipped (rare here — ship-task is ff-only). Reviewing merges directly
#   would re-diff the whole merged branch, incl. already-reviewed task commits =
#   the re-review noise this sweep exists to avoid. Deliberate; see task 061.
TASK_RE='\(task/[0-9]+(\.[0-9]+)*\)'
BOT_AUTHOR_RE='dependabot|github-actions|\[bot\]'
BOT_SUBJECT_RE='^(Bump |build\(deps\)|chore\(deps\))'

bypass_shas=()
bypass_list=""
while IFS=$'\t' read -r sha author email subject; do
  [[ -z "$sha" ]] && continue
  if [[ "$subject" =~ $TASK_RE ]]; then continue; fi
  if [[ "$author $email" =~ $BOT_AUTHOR_RE ]]; then continue; fi
  if [[ "$subject" =~ $BOT_SUBJECT_RE ]]; then continue; fi
  bypass_shas+=("$sha")
  bypass_list+="${sha:0:12}  ${subject}"$'\n'
done < <(git -C "$TAD" log --reverse --no-merges \
           --format='%H%x09%an%x09%ae%x09%s' "$BASE..$HEAD_SHA")

# --- Empty exclusion set: structurally a no-op. ----------------------------
# Everything since the last sweep went through /auto-task. Advance the marker,
# emit one OK line, exit. No claude, no worktree, no JSONL, no email — the
# digest just sees a successful run with no output.
if (( ${#bypass_shas[@]} == 0 )); then
  if advance_marker; then
    log "OK — $(git -C "$TAD" rev-list --count "$BASE..$HEAD_SHA") new commit(s), all via /auto-task; nothing to sweep."
  else
    log "WARNING: all $(git -C "$TAD" rev-list --count "$BASE..$HEAD_SHA") new commit(s) via /auto-task, but marker ${MARKER_TAG} update FAILED — re-evaluates next run."
  fi
  exit 0
fi

RANGE="${BASE:0:12}..${HEAD_SHA:0:12}"
log "${#bypass_shas[@]} bypass commit(s) to review in ${RANGE}:"
echo "$bypass_list"

# --- Prepare an isolated worktree. ------------------------------------------
# Never mutate the primary working tree (tad-pipeline also runs at 03:00 in
# the same repo). The branch carries the autofix commit out to a GitHub PR and
# is then deleted (locally + remote via `gh pr merge --delete-branch`); on
# ship-out failure it stays standing as a fallback record. The worktree
# directory is just the mechanism and is removed at the end.
mkdir -p "$WT_ROOT"
git -C "$TAD" worktree prune >/dev/null 2>&1 || true
# Claim a dated branch + worktree (PR-merged then deleted, or retained as a
# standing fallback record on ship-out failure). `git worktree
# add -b` is the atomic claim — it fails if the branch OR the path already
# exists — so retrying with an incrementing suffix is collision-free even across
# concurrent same-day reruns, and never force-deletes a standing branch or
# another run's in-progress worktree. (Scheduled runs are also serialised by the
# inherited overlap_policy:skip; this guards manual/catchup reruns too.)
AUTOFIX_BRANCH=""
WT=""
i=0
while (( i < 100 )); do
  if (( i == 0 )); then cand_branch="sweep/autofix-${TODAY}"; else cand_branch="sweep/autofix-${TODAY}.$((i + 1))"; fi
  cand_wt="${WT_ROOT}/${cand_branch//\//-}"
  if git -C "$TAD" worktree add -b "$cand_branch" "$cand_wt" "$HEAD_SHA" >/dev/null 2>&1; then
    AUTOFIX_BRANCH="$cand_branch"; WT="$cand_wt"; break
  fi
  i=$((i + 1))
done
if [[ -z "$AUTOFIX_BRANCH" ]]; then
  # 100 dated names all taken (absurd — retained autofix branches are pruned by
  # hand long before this) or a genuine local git failure. Fail the DAG so the
  # inherited handler investigates. Marker NOT advanced: the range re-reviews
  # once the worktree works again.
  log "failed to create an autofix worktree — failing the run (marker not advanced)."
  exit 1
fi
( cd "$WT" && just worktree-init >/dev/null 2>&1 ) || log "worktree-init warning (continuing)"
# Fresh worktree has its own filesystem — frontend node_modules is not shared.
# Required for `just check-all` (frontend-check/e2e); without it biome / vite
# binaries are missing. Backend .venv resolves fine via uv.
( cd "$WT/frontend" && bun install --silent 2>/dev/null ) || log "bun install warning (continuing)"

if [[ ! -x "$CLAUDE" ]]; then
  # Infrastructure broken — fail the DAG so the digest shows ATTN and the human
  # fixes the host. Marker NOT advanced (coverage resumes once claude is back).
  log "claude binary not found at $CLAUDE — failing the run (marker not advanced)."
  git -C "$TAD" worktree remove --force "$WT" >/dev/null 2>&1 || true
  git -C "$TAD" branch -D "$AUTOFIX_BRANCH" >/dev/null 2>&1 || true
  exit 1
fi

# The result file is the ONLY channel from the Claude session back to this
# script. It lives OUTSIDE the worktree so the session's `git add -A` cannot
# stage it and `git clean -fd` (on a failed check gate) cannot delete it.
RESULT_FILE="${STATE_DIR}/tad-sweep-result-${DAG_RUN_ID}.json"
rm -f "$RESULT_FILE"

# `read -d ''` (not $(cat <<EOF)) so a lone apostrophe in the prompt can't
# break the parse — same reason as dagu-autofix.sh.
IFS='' read -r -d '' PROMPT <<EOF || true
You are the TAD code-review sweep. Fresh context, today is $TODAY, run id $DAG_RUN_ID.

Working directory: $WT (a git worktree on branch $AUTOFIX_BRANCH, created from main@${HEAD_SHA:0:12}). Do everything here. Never touch the primary worktree or main.

# Overriding rule
Review fatigue is the enemy. The default outcome is SILENCE. You do not summarise, you do not write reports, you do not send email, you do not push, you do not open issues or PRs (the calling script handles ship-out). Your ONLY durable output is the single JSON result file described in step 4.

# Commits to review (these bypassed /auto-task) — there are ${#bypass_shas[@]} of them
$bypass_list

# Steps
1. For EACH commit above, run \`/review-code <sha>~1..<sha>\` (use the full sha). You are a different, fresh context — the review-code skill's authorship guard correctly does NOT fire; do the full review. Stay strictly in the code review lane. Do NOT run any linter, test suite, or \`check-all\` as part of reviewing — the deterministic gate is a separate step (step 3) and the review must never duplicate it.
2. Route every finding by these rules and NOTHING else:
   - Minor or Nit AND it carries an \`Autofix:\` line: apply that exact edit in this worktree. (The skill emitted the fix; you, a separate step, apply it — reviewer is not fixer.)
   - Critical or Major: collect it for the result file. Do NOT fix it.
   - Anything else (Minor/Nit without an Autofix line, below-threshold, speculative): DROP it silently.
3. If and only if you applied at least one autofix: run \`$CHECK_CMD\` ONCE in $WT — this single run is the autofix safety gate, nothing else. If it passes: \`git add -A && git commit -m "sweep: autofix N Minor/Nit finding(s) [$TODAY]"\` (N = how many) and capture the commit sha with \`git rev-parse HEAD\`. If it fails: do NOT commit, discard the changes (\`git checkout -- . && git clean -fd\`) — the fix is dropped silently.
4. Write your result as a SINGLE JSON object to $RESULT_FILE (overwrite it; this path is outside the worktree on purpose). Schema:
   {"reviewed": <int>, "autofix_commit": "<sha or empty string>", "autofix_count": <int>, "autofix_note": "<≤120-char 'autofixed: ...' sentence, or empty>", "findings": [{"severity": "Critical|Major", "file": "<repo-relative path>", "line": <int>, "issue": "<one line; no severity or file prefix>", "from": "<12-char sha of the commit it came from>"}]}
   "reviewed" = the number of the ${#bypass_shas[@]} listed commits on which you actually COMPLETED a full /review-code. You must review all of them, so on a complete run reviewed = ${#bypass_shas[@]}. Only Critical/Major findings go in "findings". Use an empty array if there are none. Issue text: terse, British spelling, one line, no leading severity/path.

# Notes
- This JSON file is the only thing that matters. If you cannot finish reviewing every commit, STILL write the file with the findings you have so far, and set "reviewed" to the count you actually completed (NEVER inflate it) — a short count tells the sweep the range is incomplete so it retries next run rather than skipping the unreviewed commits. Never leave the file absent.
- Do not write any other state, log, or report file.
EOF

LOG_OUT="/tmp/tad-daily-code-review-${TODAY}.log"
echo "=== tad-daily-code-review $TS — run $DAG_RUN_ID — $RANGE ===" > "$LOG_OUT"
# Pipe to tee, then read the session's real exit from PIPESTATUS — a trailing
# `echo` inside a `{ } | tee` group would otherwise mask a non-zero claude exit.
( cd "$WT" && run_claude "$PROMPT" 2>&1 ) | tee -a "$LOG_OUT"
claude_rc=${PIPESTATUS[0]}
echo "=== claude exit: $claude_rc ===" | tee -a "$LOG_OUT"

# A non-zero claude exit means the review did NOT happen (crash, OOM,
# timeout-kill, auth). Unlike a gmail send failure — where the review succeeded
# and only delivery failed, so the spec keeps the DAG green and retries — a
# review that never ran must be observable: fail the DAG so the inherited
# handler + daily digest surface it (and the handler's re-trigger recovers a
# transient blip this cycle). Marker NOT advanced; the range re-reviews on
# recovery. Tear the worktree down, keeping the branch only if a fix landed.
if (( claude_rc != 0 )); then
  log "claude exited ${claude_rc} — review did not complete; failing the run for visibility (marker not advanced)."
  rm -f "$RESULT_FILE"
  git -C "$TAD" worktree remove --force "$WT" >/dev/null 2>&1 || true
  branch_has_commits || git -C "$TAD" branch -D "$AUTOFIX_BRANCH" >/dev/null 2>&1 || true
  exit 1
fi

# --- Decide the outcome from the result file (deterministic). ---------------
# The script — not the session — owns the fingerprint, dedup, send, JSONL row,
# and marker. `should_advance` defaults true and is cleared only by the two
# outcomes that must retry next run (send failed, or no parseable result).
should_advance=1
fail_dag=0          # set when a persistent unhandled run must fail for visibility
merged=0            # set when the autofix branch was successfully PR-merged + remote-deleted
outcome=""
note=""
fingerprint=""
commit=""

# Full schema validation, not just "is .findings an array": a zero-exit session
# that writes parseable-but-malformed JSON (null/mistyped fields, an empty
# finding object) must NOT advance the marker or build a bogus escalation from
# null fields. Anything that fails this stays unhandled with should_advance=0.
RESULT_SCHEMA='
  (.reviewed | type=="number") and
  (.autofix_count | type=="number") and
  (.autofix_commit | type=="string") and
  (.autofix_note | type=="string") and
  (.findings | type=="array") and
  (.findings | all(
      ((.severity=="Critical") or (.severity=="Major"))
      and (.file|type=="string") and (.file|length>0)
      and (.issue|type=="string") and (.issue|length>0)
      and (.from|type=="string") and (.from|length>0)
      and (.line|type=="number")
  ))'
if ! jq -e "$RESULT_SCHEMA" "$RESULT_FILE" >/dev/null 2>&1; then
  # The session exited 0 but left a missing or malformed result. Treat as
  # incomplete coverage: record it, do NOT advance (re-review next run), but
  # exit 0 — a flaky one-off must not wake the gmail-dependent failure handler.
  outcome="unhandled"
  note="unhandled: missing or malformed result file"
  should_advance=0
  prev_unhandled_same_range && fail_dag=1
  log "missing/malformed result file — recording unhandled, marker NOT advanced$( ((fail_dag)) && echo ' (persistent → failing DAG)' )."
else
  autofix_note=$(jq -r '.autofix_note // ""' "$RESULT_FILE")
  n_find=$(jq '.findings | length' "$RESULT_FILE")
  reviewed=$(jq -r '.reviewed // 0' "$RESULT_FILE")
  expected=${#bypass_shas[@]}
  # Autofix success is git truth, not the session's self-report: the branch
  # carries a commit iff a fix actually landed and passed the check gate.
  if branch_has_commits; then commit=$(git -C "$TAD" rev-parse "refs/heads/${AUTOFIX_BRANCH}"); else commit=""; fi

  if ! [[ "$reviewed" =~ ^[0-9]+$ ]] || (( reviewed != expected )); then
    # Parseable but INCOMPLETE: the session is told to write partial output
    # (with a truthful, lower `reviewed`) rather than vanish if it cannot finish
    # every commit. Letting a partial result advance the marker would skip the
    # unreviewed commits forever, so treat it as unhandled → re-review the full
    # range next run.
    outcome="unhandled"
    note="unhandled: incomplete review (${reviewed:-0}/${expected} commits), not advancing"
    should_advance=0
    prev_unhandled_same_range && fail_dag=1
    log "incomplete result (${reviewed:-0}/${expected}) — recording unhandled, marker NOT advanced$( ((fail_dag)) && echo ' (persistent → failing DAG)' )."
  elif (( n_find == 0 )); then
    if branch_has_commits; then
      # Ship the autofix: push, open a PR, rebase-merge it, delete the remote
      # branch. GitHub's PR-merged email is the human-visible audit trail. On any
      # failure here, fall back to today's behaviour (standing local branch, no
      # merge) — the fix is not lost, it just doesn't reach main this cycle.
      pr_url=""
      pr_title="${autofix_note:-sweep autofix [$TODAY]}"
      pr_body=$(printf 'Automated autofix from tad-daily-code-review sweep.\n\n- run: `%s`\n- range: `%s`\n- gate: `just check-all` passed locally before commit\n\nMerged automatically by the sweep script; see ~/github/system/scripts/tad-daily-code-review.sh.\n' "$DAG_RUN_ID" "$RANGE")
      # Attempt the rebase-merge, then VERIFY the PR's real state — never trust
      # gh's exit code. A rebase-merge can land server-side while `gh pr merge`
      # still exits non-zero (async merge / branch-delete race), which used to
      # record a false "merge-failed" and strand the branch. We ask GitHub
      # whether the PR is actually merged and reconcile to that.
      if git -C "$TAD" push -u origin "$AUTOFIX_BRANCH" >/dev/null 2>&1 \
         && pr_url=$( ( cd "$TAD" && "$GH" pr create --base main --head "$AUTOFIX_BRANCH" --title "$pr_title" --body "$pr_body" ) 2>/dev/null); then
        ( cd "$TAD" && "$GH" pr merge "$pr_url" --rebase --delete-branch ) >/dev/null 2>&1 || true
      fi
      if [[ -n "$pr_url" && "$( ( cd "$TAD" && "$GH" pr view "$pr_url" --json state --jq .state ) 2>/dev/null)" == "MERGED" ]]; then
        merged=1
        outcome="autofixed"
        note="${autofix_note:-autofixed: fix committed, check green} (PR ${pr_url})"
        log "autofixed: PR ${pr_url} merged."
      else
        outcome="autofixed-merge-failed"
        note="autofixed-merge-failed: fix on ${AUTOFIX_BRANCH}, not on main${pr_url:+; PR ${pr_url}}"
        log "ship-out FAILED — standing branch ${AUTOFIX_BRANCH} retained as fallback${pr_url:+ (PR ${pr_url} unmerged)}."
      fi
    else
      outcome="clean"
      note="clean: ${reviewed} bypass commit(s) reviewed, nothing to surface"
    fi
  else
    # At least one Critical/Major. Build the human email body (file:line + source
    # commit) and the dedup fingerprint (sha1 over the sorted, normalised set of
    # severity|file|issue — deliberately NO line numbers, which drift).
    body=$(jq -r '.findings[] | "\(.severity) \(.file):\(.line) — \(.issue) (from \(.from))"' "$RESULT_FILE")
    fingerprint=$(jq -r '.findings[] | ("\(.severity)|\(.file)|\(.issue)" | ascii_downcase | gsub("\\s+"; " ") | gsub("(^ )|( $)"; ""))' "$RESULT_FILE" \
      | sort -u | shasum -a 1 | awk '{print $1}')
    fp8="${fingerprint:0:8}"

    SEVEN_DAYS_AGO=$(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-7 days' +%Y-%m-%dT%H:%M:%SZ)
    prior=$(jq -r --arg fp "$fingerprint" --arg since "$SEVEN_DAYS_AGO" \
      'select(.dag=="tad-daily-code-review" and .outcome=="escalated" and .fingerprint==$fp and .ts>=$since) | .ts' \
      "$STATE_FILE" 2>/dev/null | head -1)

    if [[ -n "$prior" ]]; then
      # Same blocker was delivered within 7 days — guards a rolled-back marker
      # from re-paging. Skip the send, record, advance.
      outcome="escalated-suppressed"
      note="escalated-suppressed: same blocker delivered <7d ago (fp ${fp8})"
      log "suppressed: blocker ${fp8} already delivered since ${SEVEN_DAYS_AGO}."
    elif [[ -z "$NOTIFY_EMAIL" ]]; then
      # Uniform mute (mirrors the other scripts): no send, no error, advance.
      # Distinct outcome (NOT "escalated") so the dedup gate — which keys only on
      # delivered "escalated" rows — never mistakes a muted blocker for a prior
      # delivery and suppresses a later genuine first send within 7 days.
      outcome="escalated-muted"
      note="escalated-muted: ${n_find} blocker(s), NOTIFY_EMAIL unset (fp ${fp8})"
      log "muted: NOTIFY_EMAIL unset; ${n_find} blocker(s) not sent."
    elif "$GWS" gmail +send --to "$NOTIFY_EMAIL" \
           --subject "[TAD SWEEP] $RANGE — needs a human" \
           --body "$body" >/dev/null 2>&1; then
      outcome="escalated"
      note="escalated: ${n_find} blocker(s) emailed (fp ${fp8})"
      log "escalated: emailed ${n_find} blocker(s) to ${NOTIFY_EMAIL}."
    else
      # Send failed. Tee the body to a durable path (NOT /tmp), record, and do
      # NOT advance — next run re-reviews and re-attempts (retry-until-delivered).
      UNDELIVERED="${STATE_DIR}/tad-sweep-undelivered-${TODAY}.txt"
      { echo "[TAD SWEEP] $RANGE — needs a human"; echo; echo "$body"; } > "$UNDELIVERED"
      outcome="escalated-send-failed"
      note="escalated-send-failed: gmail send failed; body at ${UNDELIVERED}"
      should_advance=0
      log "send FAILED — body saved to ${UNDELIVERED}, marker NOT advanced (will retry)."
    fi
  fi
fi

emit_row "$outcome" "$fingerprint" "$note" "$commit"
rm -f "$RESULT_FILE"

# --- Branch retention + worktree teardown. ---------------------------------
# Worktree always goes. Local branch:
#   merged          -> delete local + remote (don't rely on gh's --delete-branch:
#                      it can no-op when the merge landed via the async/error race).
#   has commits     -> retain (ship-out failed; standing branch is the fallback).
#   no commits      -> delete (nothing to retain).
git -C "$TAD" worktree remove --force "$WT" >/dev/null 2>&1 || true
if (( merged )); then
  git -C "$TAD" branch -D "$AUTOFIX_BRANCH" >/dev/null 2>&1 || true
  git -C "$TAD" push origin --delete "$AUTOFIX_BRANCH" >/dev/null 2>&1 || true
elif branch_has_commits; then
  log "autofix branch ${AUTOFIX_BRANCH} retained ($(git -C "$TAD" rev-list --count "${HEAD_SHA}..refs/heads/${AUTOFIX_BRANCH}") commit(s), not merged)."
else
  git -C "$TAD" branch -D "$AUTOFIX_BRANCH" >/dev/null 2>&1 || true
fi

if (( should_advance )); then
  if advance_marker; then
    log "swept ${RANGE} (${outcome}); marker ${MARKER_TAG} -> ${HEAD_SHA:0:12}."
  else
    # Near-impossible locally (refs/permission failure). Don't claim success:
    # the same range simply re-reviews next run, and the dedup gate stops a
    # delivered blocker from re-paging, so the loop is bounded and silent.
    log "WARNING: swept ${RANGE} (${outcome}) but marker ${MARKER_TAG} update FAILED — same range re-reviews next run."
  fi
else
  log "swept ${RANGE} (${outcome}); marker NOT advanced — same range retries next run."
fi

# A second consecutive unhandled run for the same range means reviews are stuck
# (e.g. model/prompt drift), not a one-off blip. Fail the DAG so the inherited
# handler + digest surface it instead of silently re-reviewing forever. The
# audit row was already written above; the handler owns the failed-run row.
if (( fail_dag )); then
  log "persistent unhandled for ${RANGE} (2nd consecutive) — failing the run for visibility."
  exit 1
fi
exit 0
