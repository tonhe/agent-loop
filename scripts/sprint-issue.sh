#!/usr/bin/env bash
# Small read-only lookups for the sprint skills, with the loop's settings filled in.
#   context N      the issue as the nightly dev agent sees it: title, body and the
#                  OWNER's comments only (issue-context.sh); refuses issues that are not
#                  the owner's, and Release/Plan issues
#   base N         the branch issue N is worked against (resolve-base.sh); exit 1 with
#                  the reason when the Base: line or base: label is unusable
#   finish TITLE   is the finish line met? {"milestone", "open": [N...], "met": bool}
#                  open = open issues in that milestone other than the loop's Release
#                  issue; met = none left (an unknown milestone is never met)
# Usage: sprint-issue.sh context|base N  |  sprint-issue.sh finish MILESTONE_TITLE
# Env:   GITHUB_REPOSITORY (default: current repo)
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
cmd=${1:-}; arg=${2:-}
repo=${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}
export GITHUB_REPOSITORY=$repo
cfg=$(bash "$here/scripts/loop-config.sh")
export OWNER_LOGIN; OWNER_LOGIN=$(jq -r .owner_login <<<"$cfg")
case "$cmd" in
  context|base) [[ "$arg" =~ ^[1-9][0-9]{0,8}$ ]] || { echo "usage: sprint-issue.sh $cmd ISSUE" >&2; exit 2; } ;;
  finish) [[ -n "$arg" ]] || { echo "usage: sprint-issue.sh finish MILESTONE_TITLE" >&2; exit 2; } ;;
  *) echo "usage: sprint-issue.sh context|base ISSUE | finish MILESTONE_TITLE" >&2; exit 2 ;;
esac
case "$cmd" in
  context) bash "$here/scripts/issue-context.sh" "$arg" ;;
  base)
    res=$(DEFAULT_BASE=$(jq -r .base_branch <<<"$cfg") bash "$here/scripts/resolve-base.sh" "$arg")
    [[ $(jq -r .ok <<<"$res") == true ]] || { echo "base: $(jq -r .reason <<<"$res")" >&2; exit 1; }
    jq -r .base <<<"$res"
    ;;
  finish)
    ms=$(gh api "repos/$repo/milestones?state=all&per_page=100" --jq "[.[] | select(.title == $(jq -Rn --arg t "$arg" '$t'))] | length")
    if [[ "$ms" == 0 ]]; then
      jq -nc --arg m "$arg" '{milestone: $m, open: [], met: false, note: "no such milestone"}'; exit 0
    fi
    gh issue list -R "$repo" --state open --milestone "$arg" --limit 500 --json number,body,labels \
      | jq -c -L "$here/lib" --arg m "$arg" 'include "meta";
          [.[] | select((is_meta_issue and ([.labels[].name] | index("release") != null)) | not) | .number] | sort
          | {milestone: $m, open: ., met: (length == 0)}'
    ;;
esac
