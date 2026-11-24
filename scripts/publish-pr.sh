#!/usr/bin/env bash
# Commit the agent's staged changes as the owner, push, and open (or update) the PR.
# Usage: publish-pr.sh ISSUE RESULT_JSON [EXISTING_PR]
# Env:   GH_TOKEN (PAT), GITHUB_REPOSITORY, GIT_AUTHOR_NAME, GIT_AUTHOR_EMAIL, BASE_BRANCH, PUSH_TOKEN
# Prints the PR URL.
set -euo pipefail
n=$1; result=$2; existing=${3:-}

git config user.name "$GIT_AUTHOR_NAME"
git config user.email "$GIT_AUTHOR_EMAIL"

msg=$(jq -r '.commit_message // empty' "$result")
[[ -z $msg ]] && msg="Resolve #$n"
git -c core.hooksPath=/dev/null commit -q -m "$msg"

remote="https://x-access-token:${PUSH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
if [[ -n $existing ]]; then
  branch=$(git rev-parse --abbrev-ref HEAD)
  git push -q "$remote" "HEAD:$branch"
  gh pr view "$existing" -R "$GITHUB_REPOSITORY" --json url --jq .url
  exit 0
fi

branch="issue-$n"
git push -q --force "$remote" "HEAD:refs/heads/$branch"

title=$(jq -r '.pr_title // empty' "$result"); [[ -z $title ]] && title=$(git log -1 --format=%s)
# Strip any attribution footer or Closes line the model added; the workflow adds its own.
model_body=$(jq -r '.pr_body // ""' "$result" \
  | grep -viE '^[^a-z0-9]*generated with \[?claude|^co-authored-by:|^closes #[0-9]+[[:space:]]*$' \
  | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')
body="$model_body

Closes #$n

<!-- agent-loop issue=$n -->"

gh pr create -R "$GITHUB_REPOSITORY" --base "$BASE_BRANCH" --head "$branch" --title "$title" --body "$body"
