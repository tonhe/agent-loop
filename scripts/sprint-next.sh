#!/usr/bin/env bash
# Which issues should a sprint start now? The queue from sprint-select.sh (ready first,
# then paired), minus those in flight, filtered so no two subagents work on the same
# files (lib/sprint.jq, pick_parallel). An issue's files are the paths its body and the
# owner's comments (the assessment included) name; for an issue in flight, also every
# file its open issue-N PR already changes. An issue that names no file runs alone.
# Usage: sprint-next.sh LIMIT MILESTONE_TITLE [IN_FLIGHT_ISSUE...]
#        LIMIT: parallel subagents, 1 to 3. MILESTONE_TITLE may be "" (no paired issues).
# Env:   GITHUB_REPOSITORY (default: current repo)
# Out:   {"start": [{issue, kind, paths}], "skipped": [{issue, why}], "queue": N}
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
limit=${1:-}; milestone=${2-}
[[ "$limit" =~ ^[1-3]$ ]] || { echo "usage: sprint-next.sh LIMIT(1-3) MILESTONE [IN_FLIGHT...]" >&2; exit 2; }
shift 2 || true
for i in "$@"; do [[ "$i" =~ ^[1-9][0-9]{0,8}$ ]] || { echo "sprint-next: bad issue number '$i'" >&2; exit 2; }; done
repo=${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}
export GITHUB_REPOSITORY=$repo
owner=$(bash "$here/scripts/loop-config.sh" | jq -r .owner_login)
sel=$(bash "$here/scripts/sprint-select.sh" "$milestone")

scope() {  # ISSUE -> paths
  gh issue view "$1" -R "$repo" --json body,comments | jq -c -L "$here/lib" --arg o "$owner" 'include "sprint"; issue_scope($o)'
}
flight='[]'
for i in "$@"; do
  p=$(scope "$i")
  prf=$(gh pr list -R "$repo" --state open --head "issue-$i" --json files --jq '[.[].files[].path]' 2>/dev/null || true)
  jq -e 'type == "array"' <<<"${prf:-x}" >/dev/null 2>&1 || prf='[]'
  flight=$(jq -c --argjson i "$i" --argjson p "$p" --argjson f "$prf" '. + [{issue: $i, paths: ($p + $f | unique)}]' <<<"$flight")
done
inflight=$(printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(. != "") | tonumber)')
queue=$(jq -c --argjson f "$inflight" '[(.ready[] | {issue: ., kind: "ready"}), (.paired[] | {issue: ., kind: "paired"})]
  | map(select(.issue as $i | $f | index($i) | not))
  | reduce .[] as $x ([]; if any(.[]; .issue == $x.issue) then . else . + [$x] end)' <<<"$sel")
# Look at the first 15 candidates only: a sprint starts at most 3 at a time.
cands='[]'
while read -r c; do
  [[ -z "$c" ]] && continue
  p=$(scope "$(jq -r .issue <<<"$c")")
  cands=$(jq -c --argjson c "$c" --argjson p "$p" '. + [$c + {paths: $p}]' <<<"$cands")
done < <(jq -c '.[:15][]' <<<"$queue")
jq -n -L "$here/lib" --argjson f "$flight" --argjson c "$cands" --argjson lim "$limit" --argjson q "$(jq length <<<"$queue")" \
  'include "sprint"; {in_flight: $f, candidates: $c} | pick_parallel($lim) + {queue: $q}'
