#!/usr/bin/env bash
# The issues a local sprint may take, in order. Two lists:
#   ready   the nightly selection (select-issues.sh scheduled, unchanged, in its order),
#           the whole ordered queue rather than the first max_issues. With a MILESTONE
#           it keeps only the open issues in that milestone: the finish line is the
#           sprint's scope (#55). Without one it is the whole queue, and its first
#           max_issues entries are what tonight's run would pick
#   paired  agent:paired issues in the finish-line milestone, which only a local agent
#           may take (lib/sprint.jq, paired_ready); none without a milestone
# Settings (owner, selection_order) come from the caller workflows (loop-config.sh), so
# a sprint orders work as the nightly run does.
# Usage: sprint-select.sh [MILESTONE_TITLE]
# Env:   GITHUB_REPOSITORY (default: current repo)
# Out:   {"ready": [N...], "paired": [N...]}
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
milestone=${1:-}
repo=${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}
export GITHUB_REPOSITORY=$repo
cfg=$(bash "$here/scripts/loop-config.sh")
export OWNER_LOGIN; OWNER_LOGIN=$(jq -r .owner_login <<<"$cfg")
export SELECTION_ORDER; SELECTION_ORDER=$(jq -r .selection_order <<<"$cfg")

ready=$(MAX_ISSUES=100 bash "$here/scripts/select-issues.sh" scheduled)
if [[ -n "$milestone" ]]; then
  # Only the finish-line milestone's open issues, keeping the nightly order.
  in_ms=$(gh issue list -R "$repo" --milestone "$milestone" --state open --limit 500 --json number --jq '[.[].number]')
  ready=$(jq -nc --argjson r "$ready" --argjson m "$in_ms" '[$r[] | select(. as $n | $m | index($n) != null)]')
fi

paired='[]'
if [[ -n "$milestone" ]]; then
  issues=$(gh issue list -R "$repo" --state open --author "$OWNER_LOGIN" --label agent:paired \
             --limit 100 --json number,labels,createdAt,author,body,milestone)
  open=$(gh issue list -R "$repo" --state open --limit 500 --json number --jq '[.[].number]')
  prs=$(gh pr list -R "$repo" --state open --limit 100 --json number,headRefName,isCrossRepository,author)
  native=$(bash "$here/scripts/native-blockers.sh")
  paired=$(jq -nc -L "$here/lib" --argjson issues "$issues" --argjson prs "$prs" --argjson open "$open" \
             --argjson native "$native" --arg owner "$OWNER_LOGIN" --arg m "$milestone" \
             'include "sprint"; {issues: $issues, prs: $prs} | paired_ready($owner; $m; $open; $native)')
fi
jq -nc --argjson r "$ready" --argjson p "$paired" '{ready: $r, paired: $p}'
