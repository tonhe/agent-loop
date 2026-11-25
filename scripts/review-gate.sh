#!/usr/bin/env bash
# Review gate: is this pull request reviewed, in which mode, and for which issue?
#
# Two modes:
#   loop   a PR the dev agent published (publish-pr.sh): head branch issue-N plus the body
#          marker. Reviewed against issue N; the review blocks.
#   owner  any other PR opened by the owner from a branch of this repository, for example
#          one pushed by the owner's interactive agent. Reviewed against the owner's
#          issues the body links (scripts/review-linked.sh); the review is advisory.
#
# In loop mode the issue number decides which issue's "Owner decision" comments and which
# issue text the review reads, so it must not be something the model can choose. It is
# taken from the head branch name, which publish-pr.sh sets (issue-N), never from the PR
# body: the body starts with text the model wrote. The body marker publish-pr.sh appends
# (<!-- agent-loop issue=N -->) must be there and every such marker must name the same N.
# N is a plain number: issue-0 and issue-036 are agent branches that name no issue, so
# they fail the check.
#
#   fork PR, or not opened by the owner        -> run=false (theirs to review, as before)
#   branch not issue-N and no marker in body   -> run=true, mode=owner (no issue output)
#   branch issue-N, marker(s) all say N        -> run=true, mode=loop, issue=N
#   anything else (no marker on an agent branch, a marker on another branch, a marker
#   naming another issue)                      -> exit 1: the required check fails
#
# Usage: review-gate.sh
# Env:   HEAD_REF, BODY, FORK (true|false), AUTHOR, OWNER_LOGIN, GITHUB_OUTPUT
# Every value arrives through the environment and is only ever compared, never evaluated.
# The outputs are words this script chose (true, false, loop, owner) and a number.
set -euo pipefail
out=${GITHUB_OUTPUT:?}
head=${HEAD_REF:-}

if [[ "${FORK:-}" == "true" || -z "${OWNER_LOGIN:-}" || "${AUTHOR:-}" != "$OWNER_LOGIN" ]]; then
  echo "Not the owner's PR, or a fork PR; nothing to review here."
  echo "run=false" >> "$out"
  exit 0
fi

# The branch-to-issue rule is lib/pr.jq, shared with the follow-up job and selection. The
# branch name and the body go in as jq string arguments; the answers are jq's own words
# (true, false) and a number.
here=$(cd "$(dirname "$0")/.." && pwd)
link=$(jq -nc -L "$here/lib" --arg h "$head" --arg b "${BODY:-}" 'include "pr"; {headRefName: $h, body: $b} | pr_link')
is_head=$(jq -r '.issue_head' <<<"$link")
has_markers=$(jq -r '.markers' <<<"$link")
agrees=$(jq -r '.agrees' <<<"$link")
n=$(jq -r '.issue // empty' <<<"$link")

if [[ "$is_head" != true && "$has_markers" != true ]]; then
  echo "Owner PR (not a loop PR): advisory review."
  echo "run=true" >> "$out"
  echo "mode=owner" >> "$out"
  exit 0
fi
if [[ "$is_head" != true ]]; then
  echo "::error::The PR body carries an agent-loop issue marker but the head branch is not an agent branch (issue-N). Refusing to guess the issue."
  exit 1
fi
if [[ "$has_markers" != true ]]; then
  echo "::error::The head branch is an agent branch (issue-N) but the PR body has no agent-loop issue marker."
  exit 1
fi
if [[ "$agrees" != true || -z "$n" ]]; then
  echo "::error::The PR body's agent-loop issue marker does not name the issue its branch (issue-N) belongs to, or the branch number is not a plain issue number."
  exit 1
fi

echo "Loop PR for issue #$n: blocking review."
{ echo "run=true"; echo "mode=loop"; echo "issue=$n"; } >> "$out"
