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

# Same shape as agent_branch in lib/base.jq. ^ and $ are whole-string anchors here.
n=""
if [[ "$head" =~ ^issue-([0-9]+)$ ]]; then n=${BASH_REMATCH[1]}; fi
markers=$(grep -oE 'agent-loop issue=[0-9]+' <<<"${BODY:-}" | grep -oE '[0-9]+$' | sort -u || true)

if [[ -z "$n" && -z "$markers" ]]; then
  echo "Owner PR (not a loop PR): advisory review."
  echo "run=true" >> "$out"
  echo "mode=owner" >> "$out"
  exit 0
fi
if [[ -z "$n" ]]; then
  echo "::error::The PR body carries an agent-loop issue marker but the head branch is not an agent branch (issue-N). Refusing to guess the issue."
  exit 1
fi
if [[ -z "$markers" ]]; then
  echo "::error::The head branch is an agent branch (issue-$n) but the PR body has no agent-loop issue marker."
  exit 1
fi
if [[ "$markers" != "$n" ]]; then
  echo "::error::The PR body names an issue other than #$n, the one its branch (issue-$n) belongs to."
  exit 1
fi

echo "Loop PR for issue #$n: blocking review."
echo "run=true" >> "$out"
echo "mode=loop" >> "$out"
echo "issue=$n" >> "$out"
