#!/usr/bin/env bash
# Decide whether the backlog manager should be asked for a milestone planning proposal
# in this run. The decision is lib/planning.jq (plan_due); this script fetches the facts.
# It changes nothing on GitHub.
#
# Usage: plan-due.sh WORK_DIR      (expects WORK_DIR/all.json from backlog-candidates.sh;
#                                   run from the repository checkout, for the roadmap check)
# Env:   GH_TOKEN, GITHUB_REPOSITORY, OWNER_LOGIN,
#        ROADMAP_PATH (default ROADMAP.md), PLAN_THRESHOLD (default 3)
# Writes WORK_DIR/planning.json: {due, reason, version, title, existing, active, facts}.
# Prints one line. Exits 0 even when GitHub cannot be asked: planning is then off for
# this run, with a warning.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
w=$1
repo=$GITHUB_REPOSITORY
owner=${OWNER_LOGIN:?}
threshold=${PLAN_THRESHOLD:-3}
[[ "$threshold" =~ ^[0-9]+$ ]] || { echo "::error::PLAN_THRESHOLD must be a number" >&2; exit 1; }

off() { jq -n --arg r "$1" '{due: false, reason: $r, version: null, title: null, existing: null, active: null, facts: null}' > "$w/planning.json"
        echo "Planning: off ($1)."; exit 0; }

milestones=$(gh api "repos/$repo/milestones?state=open&per_page=100" \
               --jq '[.[] | {number, title, due_on, open_issues, closed_issues}]') || {
  echo "::warning::Could not list milestones; milestone planning is off for this run." >&2
  off "milestones could not be read"; }
[[ $(jq length <<<"$milestones") != 0 ]] || off "no open milestone"

tags=$(gh api "repos/$repo/tags?per_page=100" --paginate --jq '.[].name' | jq -Rn '[inputs]') || {
  echo "::warning::Could not list tags; milestone planning is off for this run." >&2
  off "tags could not be read"; }

# The path is workflow input. It is only ever shown to the model as a file to read, and
# only when it is a plain relative path to a regular file in the checkout.
roadmap=${ROADMAP_PATH:-ROADMAP.md}
if ! [[ "$roadmap" =~ ^[A-Za-z0-9._/-]+$ && "$roadmap" != /* && "$roadmap" != *..* && -f "$roadmap" && ! -L "$roadmap" ]]; then
  roadmap=""
fi

decide() {  # closed plan issues JSON
  jq -n --argjson tags "$tags" --argjson milestones "$milestones" --slurpfile issues "$w/all.json" --argjson closed "$1" \
      '{tags: $tags, milestones: $milestones, issues: $issues[0], closed_plans: $closed}' \
    | jq -L "$here/lib" --arg owner "$owner" --argjson threshold "$threshold" --arg roadmap "$roadmap" \
        'include "planning"; plan_due($owner; $threshold; $roadmap)'
}

decide '[]' > "$w/planning.json"
if [[ $(jq -r .due "$w/planning.json") == true ]]; then
  # A plan the owner already closed counts too: it was answered, do not ask again.
  title=$(jq -r .title "$w/planning.json")
  [[ "$title" =~ ^Plan\ v[0-9]+\.[0-9]+$ ]] || { echo "::error::unexpected plan title" >&2; exit 1; }
  closed=$(gh issue list -R "$repo" --state closed --author "$owner" --search "\"$title\" in:title" \
             --limit 50 --json number,title,author,body) || {
    echo "::warning::Could not search closed issues; milestone planning is off for this run." >&2
    off "closed issues could not be searched"; }
  decide "$closed" > "$w/planning.json"
fi

if [[ $(jq -r .due "$w/planning.json") == true ]]; then
  echo "Planning: due ($(jq -r .reason "$w/planning.json"))."
else
  echo "Planning: off ($(jq -r .reason "$w/planning.json"))."
fi
