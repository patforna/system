#!/usr/bin/env bash
set -uo pipefail

# Daily digest of dagu DAG runs. Sent via gws gmail to NOTIFY_EMAIL.
# Designed to run via Dagu once a day (see dagu/workflow-digest.yaml).
#
# Two states per row: OK / ATTN. Anything that needs human attention
# (escalation, unhandled failure, scheduler didn't fire) is ATTN; everything
# else is OK. The row's free-text comment carries the headline; a Details
# section underneath expands each notable row with the autofix outcome,
# commit subject, and a GitHub URL when the fix produced a commit.

CONF="${HOME}/github/system/private/droplet-watchdog.conf"
[[ -f "$CONF" ]] && source "$CONF"

NOTIFY_EMAIL="${NOTIFY_EMAIL:-}"
[[ -z "$NOTIFY_EMAIL" ]] && exit 0

DAGS_DIR="${HOME}/github/system/dagu"
SYSTEM_REPO="${HOME}/github/system"
SELF="workflow-digest"
TODAY=$(date '+%Y-%m-%d')

DAGU="${DAGU:-/opt/homebrew/bin/dagu}"
AUTOFIX_LOG="${AUTOFIX_LOG:-${HOME}/.local/state/dagu-autofix.jsonl}"
DAGU_LOG_DIR="${DAGU_LOG_DIR:-${HOME}/Library/Application Support/dagu/logs}"

AUTOFIX_SINCE_24H=$(date -u -v-24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-24 hours' +%Y-%m-%dT%H:%M:%SZ)
AUTOFIX_SINCE_7D=$(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-7 days' +%Y-%m-%dT%H:%M:%SZ)

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

# Autofix entry for a specific run_id. Prints "<outcome>\t<note>\t<commit>"
# or empty if none. We match by run_id (not by time window) so the digest's
# narrative for a failed row reflects what autofix did for *that* run, not
# whatever it last did for the DAG.
autofix_for_run() {
  local run_id="$1"
  [[ -z "$run_id" || ! -f "$AUTOFIX_LOG" ]] && return
  jq -r --arg rid "$run_id" \
    'select(.run_id == $rid) | "\(.outcome)\t\(.note)\t\(.commit // "")"' \
    "$AUTOFIX_LOG" 2>/dev/null | tail -1
}

# git show -s '%s' for a sha, or empty if the sha doesn't resolve.
commit_subject() {
  local sha="$1"
  [[ -z "$sha" ]] && return
  git -C "$SYSTEM_REPO" show -s --format='%s' "$sha" 2>/dev/null || true
}

# Path of the most recent FAILED dag-run dir for a DAG (or empty). We need
# the failed dir specifically so the Details block surfaces context from the
# actual failure rather than from a more recent successful run.
latest_failed_dagrun_dir() {
  local dag="$1"
  local d="${DAGU_LOG_DIR}/${dag}"
  [[ -d "$d" ]] || return
  local rd toplog
  while IFS= read -r rd; do
    toplog=$(ls "$rd"/dag-run_*.log 2>/dev/null | head -1)
    [[ -z "$toplog" ]] && continue
    if grep -q 'status=failed' "$toplog" 2>/dev/null; then
      echo "$rd"
      return
    fi
  done < <(ls -td "$d"/dag-run_* 2>/dev/null)
}

# Show the most useful slice of the failing step's output. Errors usually
# appear at the top of stderr (followed by usage banners), while the actionable
# line in stdout typically comes near the end. So head stderr, tail stdout.
step_output_tail() {
  local rundir="$1" dag="$2" max="${3:-10}"
  [[ -d "$rundir" ]] || return
  local step_dir
  step_dir=$(ls -d "$rundir"/run_*/ 2>/dev/null | head -1)
  [[ -z "$step_dir" ]] && return
  local err_file out_file
  err_file=$(ls "$step_dir"/${dag}.*.err 2>/dev/null | head -1)
  out_file=$(ls "$step_dir"/${dag}.*.out 2>/dev/null | head -1)
  local printed=0
  if [[ -s "$err_file" ]]; then
    echo "stderr (first ${max} lines):"
    head -"$max" "$err_file"
    printed=1
  fi
  if [[ -s "$out_file" ]]; then
    [[ "$printed" == 1 ]] && echo ""
    echo "stdout (last ${max} lines):"
    tail -"$max" "$out_file"
  fi
}

# Parse a dag-run dirname like `dag-run_20260513_081400Z_<run-id>`.
rundir_started_utc() {
  local base
  base=$(basename "$1")
  if [[ "$base" =~ dag-run_([0-9]{4})([0-9]{2})([0-9]{2})_([0-9]{2})([0-9]{2})[0-9]{2}Z ]]; then
    echo "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]} UTC"
  fi
}

rundir_run_id() {
  basename "$1" | sed -E 's/^dag-run_[0-9]+_[0-9]+Z_//'
}

# If the autofix handler itself errored, print the first stderr line.
handler_crash_line() {
  local rundir="$1"
  [[ -d "$rundir" ]] || return
  local step_dir
  step_dir=$(ls -d "$rundir"/run_*/ 2>/dev/null | head -1)
  [[ -z "$step_dir" ]] && return
  local of_err
  of_err=$(ls "$step_dir"/onFailure.*.err 2>/dev/null | head -1)
  [[ -s "$of_err" ]] && head -1 "$of_err"
}

attn_count=0
fixed_count=0
rows=""
details=""

for f in "$DAGS_DIR"/*.yaml; do
  dag=$(basename "$f" .yaml)

  schedule=$(awk -F'"' '/^schedule:/ {print $2; exit}' "$f")
  dow=$(echo "$schedule" | awk '{print $5}')
  if [[ -n "$dow" && "$dow" != "*" ]]; then
    window="7d"
    autofix_since="$AUTOFIX_SINCE_7D"
  else
    window="24h"
    autofix_since="$AUTOFIX_SINCE_24H"
  fi

  # Pull both the counts and the *latest* run's status. We gate ATTN on the
  # latest, not on any failure in the window, so a transient failure that has
  # since recovered (next scheduled run, or autofix + retry) doesn't keep
  # nagging until it falls out of the 24h window.
  read -r runs ok failed latest_status < <("$DAGU" history "$dag" --last "$window" --format csv 2>/dev/null | awk -F',' '
    NR>1 {
      total++
      if (latest == "") latest = $3
      if ($3 == "Succeeded") ok++
      else if ($3 == "Failed") failed++
    }
    END { printf "%d %d %d %s\n", total+0, ok+0, failed+0, (latest=="" ? "-" : latest) }
  ')

  marker="OK   "
  comment=""
  detail_block=""

  if [[ "$latest_status" == "Failed" ]]; then
    rundir=$(latest_failed_dagrun_dir "$dag")
    failed_at=$(rundir_started_utc "$rundir")
    failed_run_id=$(rundir_run_id "$rundir")
    crash_line=$(handler_crash_line "$rundir")
    out_tail=$(step_output_tail "$rundir" "$dag" 10)

    af=$(autofix_for_run "$failed_run_id")
    af_outcome=""
    af_note=""
    af_commit=""
    if [[ -n "$af" ]]; then
      IFS=$'\t' read -r af_outcome af_note af_commit <<< "$af"
    fi

    # FIXED: autofix handled it (fixed code, or judged transient). The latest
    # run on disk is still Failed but the issue is resolved — don't alarm.
    # ATTN: latest run failed AND autofix can't or didn't resolve it.
    case "${af_outcome}" in
      fixed|transient)
        marker="FIXED"
        fixed_count=$((fixed_count + 1))
        ;;
      *)
        marker="ATTN "
        attn_count=$((attn_count + 1))
        ;;
    esac

    if [[ -n "$af_outcome" ]]; then
      # af_note already starts with "<outcome>: ..." per the autofix prompt,
      # so we pass it through verbatim rather than re-prefixing the outcome.
      comment="failed at ${failed_at}; ${af_note}"
      detail_block="  ${dag} (failed at ${failed_at}; ${af_outcome})"$'\n'
      detail_block+="    ${af_note}"$'\n'
      if [[ -n "$af_commit" ]]; then
        subject_line=$(commit_subject "$af_commit")
        short_sha="${af_commit:0:7}"
        if [[ -n "$subject_line" ]]; then
          detail_block+="    commit ${short_sha}: ${subject_line}"$'\n'
        else
          detail_block+="    commit ${short_sha}"$'\n'
        fi
        if [[ -n "$GITHUB_REPO_URL" ]]; then
          detail_block+="    ${GITHUB_REPO_URL}/commit/${af_commit}"$'\n'
        fi
      fi
    elif [[ -n "$crash_line" ]]; then
      comment="failed at ${failed_at}; autofix handler crashed"
      detail_block="  ${dag} (failed at ${failed_at}; autofix handler crashed)"$'\n'
      detail_block+="    handler error: ${crash_line}"$'\n'
    else
      comment="failed at ${failed_at}; no autofix record"
      detail_block="  ${dag} (failed at ${failed_at}; no autofix record)"$'\n'
    fi

    if [[ -n "$out_tail" ]]; then
      while IFS= read -r line; do
        detail_block+="      ${line}"$'\n'
      done <<< "$out_tail"
    fi

  elif (( runs == 0 )) && [[ "$dag" != "$SELF" ]]; then
    last_line=$("$DAGU" status "$dag" 2>/dev/null | head -1)
    if [[ -z "$last_line" ]]; then
      comment="never run yet"
      detail_block="  ${dag} (pending)"$'\n'
      detail_block+="    No history yet — first scheduled run still ahead."$'\n'
    else
      marker="ATTN "
      comment="no runs in ${window} — scheduler may not have fired"
      attn_count=$((attn_count + 1))
      detail_block="  ${dag} (stale)"$'\n'
      detail_block+="    No runs in ${window}. ${last_line}"$'\n'
      detail_block+="    Check the dagu scheduler is running and the cron expression is valid."$'\n'
    fi
  fi

  if [[ -n "$comment" ]]; then
    rows+=$(printf '%s  %-20s  %d/%d in %-3s  — %s\n' "$marker" "$dag" "$ok" "$runs" "$window" "$comment")
  else
    rows+=$(printf '%s  %-20s  %d/%d in %s\n' "$marker" "$dag" "$ok" "$runs" "$window")
  fi
  rows+=$'\n'

  if [[ -n "$detail_block" ]]; then
    details+="$detail_block"$'\n'
  fi
done

if (( attn_count > 0 )); then
  subject="[DAGU] Daily digest — ${attn_count} need attention"
elif (( fixed_count > 0 )); then
  subject="[DAGU] Daily digest — all ok (${fixed_count} auto-fixed)"
else
  subject="[DAGU] Daily digest — all ok"
fi

body="Dagu daily digest — ${TODAY}

${rows}"

if [[ -n "$details" ]]; then
  body+="Details:

${details}"
fi

body+="Markers: OK (healthy) / FIXED (autofix handled it, no action needed) / ATTN (needs you).

UI: http://localhost:8080"

/opt/homebrew/bin/gws gmail +send \
  --to "$NOTIFY_EMAIL" \
  --subject "$subject" \
  --body "$body" >/dev/null
