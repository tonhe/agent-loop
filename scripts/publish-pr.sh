#!/usr/bin/env bash
# Commit the agent's staged changes as the owner, push, and open (or update) the PR.
# Usage: publish-pr.sh ISSUE RESULT_JSON [EXISTING_PR]
# Env:   GH_TOKEN (PAT), GITHUB_REPOSITORY, GIT_AUTHOR_NAME, GIT_AUTHOR_EMAIL, BASE_BRANCH, PUSH_TOKEN
# Prints the PR URL.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
n=$1; result=$2; existing=${3:-}

# A feat prefix makes the next release a minor one, so only a type:feature issue may use
# it. On any other issue a leading feat in the commit subject and the PR title (the
# squash subject) becomes the issue type's prefix: enhance, fix, docs, test, refactor or
# chore (lib/release-mode.jq, no_feat_prefix; #61). Labels unreadable: left as written.
if ! labels=$(gh issue view "$n" -R "$GITHUB_REPOSITORY" --json labels --jq '[.labels[].name]' 2>/dev/null) \
   || ! jq -e 'type == "array"' <<<"$labels" >/dev/null 2>&1; then
  echo "::warning::Could not read the labels of #$n; its commit prefix is not checked." >&2
  labels='[]'
fi
no_feat() { jq -rn -L "$here/lib" --arg s "$1" --argjson l "$labels" \
              'include "release-mode"; ($s | split("\n")) as $x | [($x[0] | no_feat_prefix($l))] + $x[1:] | join("\n")'; }

git config user.name "$GIT_AUTHOR_NAME"
git config user.email "$GIT_AUTHOR_EMAIL"

msg=$(jq -r '.commit_message // empty' "$result")
[[ -z $msg ]] && msg="Resolve #$n"
msg=$(no_feat "$msg")
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
title=$(no_feat "$title")
# Strip any attribution footer or Closes line the model added; the workflow adds its own.
# The model's text must not carry a marker of its own: "agent-loop issue=N" is what the
# review gate, the followup job and the selection filter read to tell which issue a PR
# belongs to, and "<!-- agent-..." comments mark what the loop itself posted. So in the
# model's part no HTML comment can open and the "=" of "agent-loop issue=" is written as
# an entity (it renders the same). The marker below is the only one in the body.
model_body=$(jq -r '.pr_body // ""' "$result" \
  | grep -viE '^[^a-z0-9]*generated with \[?claude|^co-authored-by:|^closes #[0-9]+[[:space:]]*$' \
  | sed -e 's/<!--/\&lt;!--/g' -e 's/agent-loop\([[:space:]]*\)issue\([[:space:]]*\)=/agent-loop\1issue\2\&#61;/g' \
  | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')
body="$model_body

Closes #$n

<!-- agent-loop issue=$n -->"

gh pr create -R "$GITHUB_REPOSITORY" --base "$BASE_BRANCH" --head "$branch" --title "$title" --body "$body"
