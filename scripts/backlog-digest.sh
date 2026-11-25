#!/usr/bin/env bash
# Print the backlog run's digest message (the Digest step pipes it to discord.sh).
# The apply step writes WORK_DIR/digest.md. When it did not get that far, say what is
# true: "Nothing new to triage." only when there really was nothing to do. A night with
# no candidates can still have had work (a milestone plan was due, so Claude ran), and
# if that failed the digest must not read as a quiet night.
#
# Usage: backlog-digest.sh WORK_DIR
# Env:   GITHUB_REPOSITORY, COUNT (candidates), WORK (true|false: was there anything for
#        Claude to do), JOB_STATUS. COUNT and WORK are empty when the gather step failed.
set -euo pipefail
w=$1
name=${GITHUB_REPOSITORY#*/}
count=${COUNT:-}; work=${WORK:-}; status=${JOB_STATUS:-unknown}

if [[ -s "$w/digest.md" ]]; then
  msg=$(cat "$w/digest.md")
elif [[ "$work" == "false" ]]; then
  msg="**Backlog: $name**"$'\n'"Nothing new to triage."
elif [[ "$work" == "true" && "$count" == "0" ]]; then
  msg="**Backlog: $name** milestone planning was due, but the run finished with status $status before a proposal was applied. Nothing was triaged and no Plan issue was filed."
else
  msg="**Backlog: $name** finished with status $status."
fi
# The blocker audit (scripts/audit-blockers.sh) runs whether or not there was anything to
# triage; its text is empty when the blockers in text and the native links agree.
if [[ -s "$w/audit.txt" ]]; then
  msg+=$'\n'"$(cat "$w/audit.txt")"
fi
if [[ -s "$w/claude/usage.json" ]]; then
  msg+=$'\n'"Claude: $(jq -r '"\(.num_turns) turns, \(.duration_ms/60000 | floor) min"' "$w/claude/usage.json")"
fi
printf '%s\n' "$msg"
