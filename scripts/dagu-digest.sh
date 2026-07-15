#!/usr/bin/env bash
set -uo pipefail

# Daily digest of the dagu jobs. Sent via gws gmail to NOTIFY_EMAIL.
# Run LAST in the reconciler's serial pass (scripts/dagu-reconcile), so what it reports
# reflects everything that ran in this same pass.
#
# WHAT THIS REPORTS, AND WHY IT CHANGED
# -------------------------------------
# It used to report, per DAG, "did the run at the scheduled instant succeed?", taken from
# dagu's status store. That was wrong twice over on a laptop:
#
#   1. dagu 2.7.2 persists `Failed` for a run whose own log says `status=succeeded` after
#      a retry. So the digest confidently reported failures for work that had completed.
#   2. "The Mac was asleep at 03:00" is not a failure, but it rendered as one — so the
#      digest cried wolf, and a monitoring system that cries wolf is worse than none.
#
# So it now reports FRESHNESS instead: how long since each job last actually succeeded
# (a marker touched by dagu itself on success — see base.yaml handler_on.success), against
# the SLO in scripts/dagu-jobs.conf. The governing principle:
#
#   ALERT ON FAILURE-WITH-OPPORTUNITY. NEVER ON ABSENCE-WITHOUT-OPPORTUNITY.
#
# A job that is stale because the machine was off or offline is not a problem — it's the
# design working (being off IS the pause; there is nothing to catch up). A job that is
# stale *despite* the machine having been awake and online is a real failure. The
# reconciler records an "opportunity" (its tick file) only when it is awake AND online,
# which is what lets those two cases be told apart. This is what makes a 3-week holiday
# generate no noise at all.

CONF="${HOME}/github/system/private/droplet-watchdog.conf"
[[ -f "$CONF" ]] && source "$CONF"

NOTIFY_EMAIL="${NOTIFY_EMAIL:-}"
[[ -z "$NOTIFY_EMAIL" ]] && exit 0

SYSTEM_REPO="${HOME}/github/system"
JOBS_CONF="${SYSTEM_REPO}/scripts/dagu-jobs.conf"
SELF="workflow-digest"   # this digest's own DAG — it can't report on its own freshness (see loop)
TODAY=$(date '+%Y-%m-%d')

AUTOFIX_LOG="${AUTOFIX_LOG:-${HOME}/.local/state/dagu-autofix.jsonl}"
DAGU_LOG_DIR="${DAGU_LOG_DIR:-${HOME}/Library/Application Support/dagu/logs}"
MARKER_DIR="${MARKER_DIR:-${HOME}/.local/state/dagu-success}"
TICK_FILE="${TICK_FILE:-${HOME}/.local/state/dagu-reconcile/last-tick}"

# Pending local drift, written by drift-check on any local run. Path must match
# DRIFT_PENDING_FILE in scripts/drift-check.
DRIFT_PENDING_FILE="${DRIFT_PENDING_FILE:-${HOME}/.local/state/drift-pending-$(hostname -s 2>/dev/null || hostname).txt}"

now=$(date +%s)

mtime()   { stat -f %m "$1" 2>/dev/null || echo 0; }
age_of()  { local m; m=$(mtime "$1"); (( m == 0 )) && { echo -1; return; }; echo $(( now - m )); }

# Compact human duration: 45m / 6h / 3d.
human() {
  local s="$1"
  (( s < 0 ))     && { echo "never"; return; }
  (( s < 3600 ))  && { echo "$((s / 60))m"; return; }
  (( s < 172800 ))&& { echo "$((s / 3600))h"; return; }
  echo "$((s / 86400))d"
}

# Derive https://github.com/<owner>/<repo> from the system repo's origin.
github_repo_url() {
  local url
  url=$(git -C "$SYSTEM_REPO" remote get-url origin 2>/dev/null) || return
  case "$url" in
    git@github.com:*) echo "https://github.com/${url#git@github.com:}" | sed 's/\.git$//' ;;
    https://github.com/*) echo "${url%.git}" ;;
  esac
}
GITHUB_REPO_URL=$(github_repo_url)

# Most recent FAILED dag-run dir for a DAG (or empty) — context for a job that is stale
# because it keeps failing, rather than because the Mac was away.
latest_failed_dagrun_dir() {
  # NB: split declarations — under `set -u`, bash does not reliably resolve a variable
  # assigned earlier in the SAME `local` statement.
  local dag="$1"
  local d="${DAGU_LOG_DIR}/${dag}"
  local rd toplog
  [[ -d "$d" ]] || return
  while IFS= read -r rd; do
    toplog=$(ls "$rd"/dag-run_*.log 2>/dev/null | head -1)
    [[ -z "$toplog" ]] && continue
    if grep -q 'status=failed' "$toplog" 2>/dev/null; then echo "$rd"; return; fi
  done < <(ls -td "$d"/dag-run_* 2>/dev/null)
}

# Errors surface at the top of stderr (followed by usage banners); the actionable line in
# stdout is usually near the end. So head stderr, tail stdout.
step_output_tail() {
  local rundir="$1" dag="$2" max="${3:-8}" step_dir err_file out_file printed=0
  [[ -d "$rundir" ]] || return
  step_dir=$(ls -d "$rundir"/run_*/ 2>/dev/null | head -1)
  [[ -z "$step_dir" ]] && return
  err_file=$(ls "$step_dir"/${dag}.*.err 2>/dev/null | head -1)
  out_file=$(ls "$step_dir"/${dag}.*.out 2>/dev/null | head -1)
  if [[ -s "$err_file" ]]; then echo "stderr (first ${max}):"; head -"$max" "$err_file"; printed=1; fi
  if [[ -s "$out_file" ]]; then
    [[ "$printed" == 1 ]] && echo ""
    echo "stdout (last ${max}):"; tail -"$max" "$out_file"
  fi
}

rundir_run_id() { basename "$1" | sed -E 's/^dag-run_[0-9]+_[0-9]+Z_//'; }

autofix_for_run() {
  local run_id="$1"
  [[ -z "$run_id" || ! -f "$AUTOFIX_LOG" ]] && return
  jq -r --arg rid "$run_id" 'select(.run_id == $rid) | "\(.outcome)\t\(.note)"' "$AUTOFIX_LOG" 2>/dev/null | tail -1
}

tick_age=$(age_of "$TICK_FILE")

attn_count=0
idle_count=0
drift_count=0
rows=""
details=""

while read -r job slo_hours; do
  [[ -z "$job" || "$job" == \#* ]] && continue

  marker_file="${MARKER_DIR}/${job}"
  age=$(age_of "$marker_file")
  slo_secs=$((slo_hours * 3600))

  # The digest cannot report on its own freshness: it reads the success markers BEFORE its
  # own handler_on.success stamps this run, so it would always see itself one run stale and
  # flag ATTN on itself every single time. The email you're holding is proof this run
  # succeeded, so treat SELF as fresh (age 0 → OK). Trade-off: a digest run that fails to
  # send produces no email at all (the absence is the signal) and is retried at the next
  # reconciler tick — the marker is untouched here, so that retry path is preserved.
  [[ "$job" == "$SELF" ]] && age=0

  marker_m=$(mtime "$marker_file")
  due=$(( marker_m + slo_secs ))   # 0 + slo when the job has never succeeded => long overdue
  tick_m=$(mtime "$TICK_FILE")

  marker="OK   "
  comment=""
  detail_block=""

  if (( age >= 0 && age < slo_secs )); then
    marker="OK   "
  elif (( tick_m > 0 && tick_m < due )); then
    # Stale, but the machine has had NO opportunity since it fell due — it was off or
    # offline the whole time. This is the design working, not a fault. Never ATTN.
    marker="IDLE "
    comment="no opportunity since due — Mac off/offline"
    idle_count=$((idle_count + 1))
  else
    # Stale DESPITE opportunity: the reconciler was awake and online and either ran this
    # and it failed, or couldn't run it. That is real signal.
    marker="ATTN "
    comment="stale despite opportunity"
    attn_count=$((attn_count + 1))

    rundir=$(latest_failed_dagrun_dir "$job")
    if [[ -n "$rundir" ]]; then
      af=$(autofix_for_run "$(rundir_run_id "$rundir")")
      af_note=""
      [[ -n "$af" ]] && IFS=$'\t' read -r _ af_note <<< "$af"
      detail_block="  ${job} (last success $(human "$age") ago; slo ${slo_hours}h)"$'\n'
      [[ -n "$af_note" ]] && detail_block+="    ${af_note}"$'\n'
      while IFS= read -r line; do
        [[ -n "$line" ]] && detail_block+="      ${line}"$'\n'
      done <<< "$(step_output_tail "$rundir" "$job" 8)"
    else
      detail_block="  ${job} (last success $(human "$age") ago; slo ${slo_hours}h — no failed run on disk)"$'\n'
    fi
  fi

  # Pending local drift is orthogonal to freshness: drift-check can be perfectly fresh and
  # still have untracked items waiting on a human. Surface it on drift-check's row, but
  # never as ATTN — reconciling drift is a decision, not a failure.
  if [[ "$job" == "drift-check" && "$marker" == "OK   " && -s "$DRIFT_PENDING_FILE" ]]; then
    n_drift=$(grep -c . "$DRIFT_PENDING_FILE")
    marker="DRIFT"
    comment="${n_drift} untracked item(s) pending reconciliation"
    drift_count=$((drift_count + n_drift))
    detail_block="  drift-check (${n_drift} untracked item(s) pending)"$'\n'
    while IFS= read -r line; do
      [[ -n "$line" ]] && detail_block+="    - ${line}"$'\n'
    done < "$DRIFT_PENDING_FILE"
    detail_block+="    Reconcile (track in Brewfile/manual-apps.conf, or drop), then re-run drift-check."$'\n'
  fi

  if [[ -n "$comment" ]]; then
    rows+=$(printf '%s  %-22s  %-5s ago (slo %sh)  — %s\n' "$marker" "$job" "$(human "$age")" "$slo_hours" "$comment")
  else
    rows+=$(printf '%s  %-22s  %-5s ago (slo %sh)\n' "$marker" "$job" "$(human "$age")" "$slo_hours")
  fi
  rows+=$'\n'
  [[ -n "$detail_block" ]] && details+="$detail_block"$'\n'
done < "$JOBS_CONF"

if (( attn_count > 0 )); then
  subject="[DAGU] Daily digest — ${attn_count} need attention"
else
  extras=()
  (( idle_count  > 0 )) && extras+=("${idle_count} idle by design")
  (( drift_count > 0 )) && extras+=("${drift_count} drift pending")
  if (( ${#extras[@]} > 0 )); then
    suffix=$(printf '%s, ' "${extras[@]}"); suffix="${suffix%, }"
    subject="[DAGU] Daily digest — all ok (${suffix})"
  else
    subject="[DAGU] Daily digest — all ok"
  fi
fi

body="Dagu daily digest — ${TODAY}
Ages are time since last SUCCESS. Last reconcile tick: $(human "$tick_age") ago.

${rows}"

[[ -n "$details" ]] && body+="Details:

${details}"

body+="Markers:
  OK    fresh — succeeded within its SLO
  DRIFT untracked system state waiting on a decision (not a failure)
  IDLE  stale, but the Mac was off/offline since it fell due — expected, no action
  ATTN  stale despite the Mac being awake and online — needs you

Jobs have no cron schedule; they run whenever the Mac is awake and online and they are
overdue (scripts/dagu-reconcile). Being away is not a failure.

UI: http://localhost:8080"

/opt/homebrew/bin/gws gmail +send \
  --to "$NOTIFY_EMAIL" \
  --subject "$subject" \
  --body "$body" >/dev/null
