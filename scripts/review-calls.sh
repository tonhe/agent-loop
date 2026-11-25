#!/usr/bin/env bash
# Run the Claude review call(s), one per prompt review-prompts.sh wrote, one after the
# other. Each call is run-claude.sh with its own wall-clock timeout (TIMEOUT_MIN) and
# turn limit; its exit code is kept next to its result for review-post.sh.
#
#   loop   the first failing call ends the step with that call's exit code, as before:
#          a loop PR is not reviewed in part.
#   owner  a failing call is noted and the next one runs; the step ends 0. review-post.sh
#          names the parts that were not reviewed.
#
# So that several calls cannot run the job into its own timeout (which would fail the
# check in either mode), the calls share a time budget: JOB_TIMEOUT_MIN minus
# RESERVE_MIN, counted from the start of this script. A call gets what is left of it,
# at most TIMEOUT_MIN; with less than a minute left the remaining calls are not started
# (exit code 125 for those).
#
# Usage: review-calls.sh WORK_DIR SCHEMA_FILE       (run in the PR checkout)
# Env:   MODE (loop|owner), MODEL, MAX_TURNS, TIMEOUT_MIN, ALLOWED_TOOLS,
#        CLAUDE_CODE_OAUTH_TOKEN, JOB_TIMEOUT_MIN (optional: no budget without it),
#        RESERVE_MIN (default 15: setup before and posting after the calls)
# Writes WORK_DIR/groups/N/{rc,result.json,raw.json,usage.json}
# This step holds the Claude token and no GitHub token; it only starts run-claude.sh.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
work=$1; schema=$2
mode=${MODE:-loop}
: "${TIMEOUT_MIN:?}"
[[ "$TIMEOUT_MIN" =~ ^[1-9][0-9]{0,3}$ ]] || { echo "::error::TIMEOUT_MIN must be a whole number of minutes" >&2; [[ "$mode" == owner ]] && exit 0; exit 1; }

n=0
if [[ -f "$work/plan.json" ]]; then n=$(jq '.groups | length' "$work/plan.json" 2>/dev/null || echo 0); fi
if [[ ! "$n" =~ ^[1-9][0-9]*$ ]]; then
  if [[ "$mode" == owner ]]; then
    echo "::warning::No review prompt was built, so Claude was not asked. The review of an owner PR is advisory; the check still passes."
    exit 0
  fi
  echo "::error::No review prompt was built"
  exit 1
fi

deadline=""
if [[ "${JOB_TIMEOUT_MIN:-}" =~ ^[1-9][0-9]{0,3}$ ]]; then
  reserve=${RESERVE_MIN:-15}; [[ "$reserve" =~ ^[0-9]{1,3}$ ]] || reserve=15
  deadline=$(( $(date +%s) + (JOB_TIMEOUT_MIN - reserve) * 60 ))
fi

failed=0
for ((i = 0; i < n; i++)); do
  d="$work/groups/$i"
  t=$TIMEOUT_MIN
  if [[ -n "$deadline" ]]; then
    left=$(( (deadline - $(date +%s)) / 60 ))
    if (( left < 1 )); then
      echo "::warning::Review part $((i + 1)) of $n was not started: the job's time budget is used up."
      echo 125 > "$d/rc"; rc=125
      failed=$((failed + 1))
      [[ "$mode" == owner ]] || exit "$rc"
      continue
    fi
    (( left < t )) && t=$left
  fi
  echo "Review part $((i + 1)) of $n (up to $t minute(s))"
  TIMEOUT_MIN=$t bash "$here/scripts/run-claude.sh" "$d/prompt.md" "$schema" "$d"
  rc=$?
  echo "$rc" > "$d/rc"
  if [[ $rc -ne 0 ]]; then
    failed=$((failed + 1))
    [[ "$mode" == owner ]] || exit "$rc"
  fi
done

if (( failed > 0 )); then
  echo "::warning::$failed of $n review call(s) failed. The review of an owner PR is advisory; the check still passes and the comment says which part is missing."
fi
exit 0
