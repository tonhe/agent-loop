#!/usr/bin/env bash
# Open the PR for a sprint subagent's work, the way the nightly dev job does, so review,
# follow-up and the merge gate treat it as a loop PR (branch issue-N, body marker).
#   1. The issue's base branch is resolved as in CI (resolve-base.sh).
#   2. Everything the worktree changed since it left the base (commits, staged, unstaged,
#      untracked) becomes one patch, applied in a fresh worktree of origin/BASE with
#      hooks off: nothing the agent wrote into .git runs, as in CI's clean checkout.
#   3. check-diff.sh refuses protected_paths and .github/ there, as in CI.
#   4. publish-pr.sh commits as the owner, pushes issue-N and opens the PR.
#   5. A result with live_check labels the PR agent:live-check: merge-gate.sh then waits
#      for the owner's "Live check passed <sha>" comment.
# The required checks on the PR (tests, lab, agent-review) are the verification; this
# script does not run the tests again.
# Usage: sprint-publish.sh ISSUE RESULT_JSON     (in the issue's worktree)
#        RESULT_JSON: schemas/dev-result.json fields (commit_message, pr_title, pr_body)
#        plus optional live_check {commands, why}
# Env:   GITHUB_REPOSITORY (default: current repo)
# Out:   the PR URL. Exit 1 refused or failed, 2 usage.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
n=${1:-}; result=${2:-}
[[ "$n" =~ ^[1-9][0-9]{0,8}$ && -s "$result" ]] || { echo "usage: sprint-publish.sh ISSUE RESULT_JSON" >&2; exit 2; }
result=$(realpath "$result")
repo=${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}
export GITHUB_REPOSITORY=$repo
cfg=$(bash "$here/scripts/loop-config.sh")
export OWNER_LOGIN; OWNER_LOGIN=$(jq -r .owner_login <<<"$cfg")
export DEFAULT_BASE; DEFAULT_BASE=$(jq -r .base_branch <<<"$cfg")
export PROTECTED_PATHS; PROTECTED_PATHS=$(jq -r .protected_paths <<<"$cfg")
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL
GIT_AUTHOR_NAME=$(jq -r '.git_author_name | select(. != "")' <<<"$cfg"); GIT_AUTHOR_NAME=${GIT_AUTHOR_NAME:-$(git config user.name)}
GIT_AUTHOR_EMAIL=$(jq -r '.git_author_email | select(. != "")' <<<"$cfg"); GIT_AUTHOR_EMAIL=${GIT_AUTHOR_EMAIL:-$(git config user.email)}

res=$(bash "$here/scripts/resolve-base.sh" "$n")
[[ $(jq -r .ok <<<"$res") == true ]] || { echo "sprint-publish: REFUSED: $(jq -r .reason <<<"$res")" >&2; exit 1; }
export BASE_BRANCH; BASE_BRANCH=$(jq -r .base <<<"$res")

git fetch -q origin "$BASE_BRANCH"
mb=$(git merge-base HEAD "origin/$BASE_BRANCH")
work=$(mktemp -d); clean="$work/clean"
cleanup() { git worktree remove --force "$clean" 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT
git add -A
git diff --cached --binary "$mb" > "$work/change.patch"
[[ -s "$work/change.patch" ]] || { echo "sprint-publish: REFUSED: nothing changed since $BASE_BRANCH" >&2; exit 1; }

git -c core.hooksPath=/dev/null worktree add -q --detach "$clean" "origin/$BASE_BRANCH"
cd "$clean"
git -c core.hooksPath=/dev/null apply --index "$work/change.patch"
set +e; bash "$here/scripts/check-diff.sh" >&2; d=$?; set -e
if (( d == 2 )); then echo "sprint-publish: REFUSED: no change" >&2; exit 1; fi
if (( d != 0 )); then echo "sprint-publish: REFUSED: protected paths changed (see above); stop and ask for an Owner decision" >&2; exit 1; fi

export PUSH_TOKEN; PUSH_TOKEN=$(gh auth token)
pr=$(bash "$here/scripts/publish-pr.sh" "$n" "$result" | tail -1)
if jq -e '.live_check.commands? // "" | length > 0' "$result" >/dev/null; then
  gh label create agent:live-check -R "$repo" --color fbca04 \
    --description "Waits for the owner's live check before the merge gate allows it" >/dev/null 2>&1 || true
  gh pr edit "$pr" -R "$repo" --add-label agent:live-check >/dev/null
  gh pr comment "$pr" -R "$repo" --body "$(jq -r -L "$here/lib" 'include "meta"; "<!-- agent-sprint -->\n**Waiting on the owner'"'"'s live check.** \(.live_check.why // "" | defang_markers)\n\nRun on the PR head:\n\n```\n\(.live_check.commands | gsub("```"; "ʼʼʼ"))\n```\n\nThen comment `Live check passed <first 7 characters of the head commit>` (or `Live check failed ...`). The merge gate waits for it."' "$result")" >/dev/null
fi
echo "$pr"
