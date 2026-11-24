#!/usr/bin/env bash
# Choose which issues the dev agent works on. Prints a JSON array of numbers.
# Usage: select-issues.sh MODE [ISSUE]
#   MODE=scheduled  owner-authored, agent:ready, not in progress, no open agent PR; oldest first
#   MODE=manual     the given issue, if owner-authored and open (you running it is the approval)
#   MODE=urgent     the given issue, if owner-authored, open, and labeled agent:urgent
# Env: GH_TOKEN, GITHUB_REPOSITORY, OWNER_LOGIN, MAX_ISSUES
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
mode=$1
issue=${2:-}

case "$mode" in
  manual|urgent)
    [[ "$issue" =~ ^[0-9]+$ ]] || { echo "::error::Need an issue number, got '$issue'" >&2; exit 1; }
    data=$(gh issue view "$issue" -R "$GITHUB_REPOSITORY" --json number,state,author,labels)
    jq -e --arg owner "$OWNER_LOGIN" --arg mode "$mode" '
      .state == "OPEN" and .author.login == $owner
      and ($mode != "urgent" or ([.labels[].name] | index("agent:urgent") != null))
    ' <<<"$data" >/dev/null || {
      echo "::error::Issue #$issue is not eligible (must be open, opened by $OWNER_LOGIN, and for urgent runs labeled agent:urgent)." >&2
      echo '[]'; exit 0; }
    echo "[$issue]"
    ;;
  scheduled)
    issues=$(gh issue list -R "$GITHUB_REPOSITORY" --state open --author "$OWNER_LOGIN" \
               --label agent:ready --limit 100 --json number,labels,createdAt,author)
    prs=$(gh pr list -R "$GITHUB_REPOSITORY" --state open --limit 100 --json number,body)
    jq -nc --argjson issues "$issues" --argjson prs "$prs" '{issues: $issues, prs: $prs}' \
      | jq -c --arg owner "$OWNER_LOGIN" --argjson max "${MAX_ISSUES:-3}" -f "$here/lib/select.jq"
    ;;
  *) echo "::error::unknown mode $mode" >&2; exit 1 ;;
esac
