#!/usr/bin/env bash
# Before a scheduled dev run selects issues: wait for a backlog (triage) run of the same
# repository that has not finished, so the selection does not read labels that triage is
# about to change. Polls the caller's backlog workflow until none of its runs is unfinished
# (in progress, queued, or held back as pending/waiting/requested) or the cap is reached,
# then lets the run go on either way.
#
# Always exits 0. A wait that cannot be done must never cost a night of dev work: if the
# runs cannot be listed (the caller's token lacks `actions: read`, the workflow file name is
# wrong, GitHub is down) this warns and the run goes on without waiting.
#
# Usage: wait-backlog.sh
# Env: GH_TOKEN, GITHUB_REPOSITORY
#      BACKLOG_WORKFLOW  the caller's backlog workflow file (default agent-backlog.yml)
#      WAIT_MINUTES      cap in minutes (default 15, at most max_minutes); 0 = do not wait
#      WAIT_INTERVAL     seconds between polls (default 30)
# Prints what it did. With GITHUB_OUTPUT set it also writes
#      waited=<seconds slept>
#      note=<one line for the digest; empty when there was no wait>
set -uo pipefail

# The select job's timeout-minutes in dev.yml has to cover this plus the selection.
max_minutes=20
workflow=${BACKLOG_WORKFLOW:-}
[[ -n "$workflow" ]] || workflow=agent-backlog.yml
minutes=${WAIT_MINUTES:-15}
interval=${WAIT_INTERVAL:-30}

warn() { echo "::warning::$*" >&2; }
finish() {  # seconds waited, line for the log, note for the digest
  echo "$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    { echo "waited=$1"; echo "note=$3"; } >> "$GITHUB_OUTPUT"
  fi
  exit 0
}

if ! [[ "$minutes" =~ ^[0-9]{1,6}$ ]]; then
  warn "Backlog wait: WAIT_MINUTES '$minutes' is not a number of minutes; using 15."
  minutes=15
fi
minutes=$((10#$minutes))
if (( minutes > max_minutes )); then
  warn "Backlog wait: $minutes minutes is more than the select job allows; using $max_minutes."
  minutes=$max_minutes
fi
if ! [[ "$interval" =~ ^[0-9]{1,4}$ ]] || (( 10#$interval < 1 )); then
  warn "Backlog wait: WAIT_INTERVAL '$interval' is not a number of seconds above 0; using 30."
  interval=30
fi
interval=$((10#$interval))
cap=$((minutes * 60))

if (( cap == 0 )); then
  finish 0 "Backlog wait is switched off." ""
fi

# Number of runs of the backlog workflow that have not completed. One listing of the newest
# runs covers every unfinished state; a non-zero exit means "could not tell".
unfinished() {
  local runs
  runs=$(timeout 60 gh run list -R "$GITHUB_REPOSITORY" --workflow "$workflow" --limit 20 --json status,databaseId) || return 1
  jq -e -r 'if type == "array" then [.[] | select(.status != "completed")] | length else error("not a list") end' <<<"$runs" 2>/dev/null
}

waited=0
while :; do
  if ! n=$(unfinished); then
    if (( waited == 0 )); then
      warn "Backlog wait: could not list runs of $workflow, so this run does not wait for triage. The caller workflow needs 'actions: read' under permissions, and backlog_workflow must name its backlog workflow file."
      finish 0 "Could not check for a backlog run; not waiting." ""
    fi
    warn "Backlog wait: could not list runs of $workflow after waiting $waited s; going on."
    finish "$waited" "Waited $waited s for a backlog run, then could not read its state." \
      "Waited $waited s for a backlog run, then could not read its state; issues were selected anyway."
  fi
  if (( n == 0 )); then
    if (( waited == 0 )); then
      finish 0 "No backlog run in progress; not waiting." ""
    fi
    finish "$waited" "Waited $waited s for a backlog run to finish." \
      "Waited $waited s for a backlog run to finish before selecting issues."
  fi
  if (( waited >= cap )); then
    warn "Backlog wait: a run of $workflow was still going after $waited s; selecting issues anyway."
    finish "$waited" "A backlog run was still going after $waited s; gave up waiting." \
      "A backlog run was still going after $waited s; issues were selected anyway."
  fi
  (( waited == 0 )) && echo "A run of $workflow has not finished; waiting up to $cap s."
  step=$interval
  (( step > cap - waited )) && step=$((cap - waited))
  sleep "$step"
  waited=$((waited + step))
done
