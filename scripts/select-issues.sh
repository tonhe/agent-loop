#!/usr/bin/env bash
# Choose which issues the dev agent works on. Prints a JSON array of numbers.
# Usage: select-issues.sh MODE [ISSUE]
#   MODE=scheduled  owner-authored, agent:ready, not in progress, not agent:paired, not blocked ("Blocked by #N"
#                   text or a native dependency), no open PR of the owner's on branch issue-N; ordered by milestone group, then by
#                   SELECTION_ORDER (lib/select.jq). A type:feature issue only when it is in a
#                   milestone approved for release (lib/release-mode.jq, #61)
#   MODE=manual     the given issue, if owner-authored and open (you running it is the approval: blockers
#                   and agent:paired included)
#   MODE=urgent     the given issue, if owner-authored, open, and labeled agent:urgent
#   In every mode the Release / Plan issues the loop files itself are refused (lib/meta.jq).
# Env: GH_TOKEN, GITHUB_REPOSITORY, OWNER_LOGIN, MAX_ISSUES,
#      SELECTION_ORDER (oldest | type; default oldest; anything else is an error)
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
mode=$1
issue=${2:-}
order=${SELECTION_ORDER:-oldest}
if [[ "$order" != oldest && "$order" != type ]]; then
  echo "::error::selection_order must be 'oldest' or 'type'." >&2
  exit 1
fi

case "$mode" in
  manual|urgent)
    [[ "$issue" =~ ^[0-9]+$ ]] || { echo "::error::Need an issue number, got '$issue'" >&2; exit 1; }
    data=$(gh issue view "$issue" -R "$GITHUB_REPOSITORY" --json number,state,author,labels,body)
    jq -e -L "$here/lib" --arg owner "$OWNER_LOGIN" --arg mode "$mode" '
      include "meta";
      .state == "OPEN" and .author.login == $owner and (is_meta_issue | not)
      and ($mode != "urgent" or ([.labels[].name] | index("agent:urgent") != null))
    ' <<<"$data" >/dev/null || {
      echo "::error::Issue #$issue is not eligible (must be open, opened by $OWNER_LOGIN, not a Release or Plan issue filed by the loop, and for urgent runs labeled agent:urgent)." >&2
      echo '[]'; exit 0; }
    echo "[$issue]"
    ;;
  scheduled)
    issues=$(gh issue list -R "$GITHUB_REPOSITORY" --state open --author "$OWNER_LOGIN" \
               --label agent:ready --limit 100 --json number,labels,createdAt,author,body,milestone)
    open=$(gh issue list -R "$GITHUB_REPOSITORY" --state open --limit 500 --json number --jq '[.[].number]')
    # Which issues already have an open PR is decided from the head branch, the fork flag
    # and the author (lib/select.jq, lib/pr.jq), not from the PR body.
    prs=$(gh pr list -R "$GITHUB_REPOSITORY" --state open --limit 100 --json number,body,headRefName,isCrossRepository,author)
    # Native dependencies; {} with a warning if the API is unavailable.
    native=$(bash "$here/scripts/native-blockers.sh")
    # Open milestones, for milestone priority. Without them the order is oldest first, as before.
    milestones=$(gh api "repos/$GITHUB_REPOSITORY/milestones?state=open&per_page=100" \
                   --jq '[.[] | {number, dueOn: .due_on, description}]') || {
      echo "::warning::Could not list milestones; milestone priority is off and no type:feature issue is picked (maintenance mode) for this run." >&2
      milestones='[]'; }
    jq -nc --argjson issues "$issues" --argjson prs "$prs" '{issues: $issues, prs: $prs}' \
      | jq -c --arg owner "$OWNER_LOGIN" --argjson max "${MAX_ISSUES:-3}" --argjson open "$open" \
           --argjson native "$native" --argjson milestones "$milestones" --arg order "$order" -L "$here/lib" -f "$here/lib/select.jq"
    ;;
  *) echo "::error::unknown mode $mode" >&2; exit 1 ;;
esac
