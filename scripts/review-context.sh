#!/usr/bin/env bash
# Print review feedback on a PR for the fix round: only from CodeRabbit, the
# github-actions bot (agent review), and the owner.
# Usage: review-context.sh PR     Env: GH_TOKEN, GITHUB_REPOSITORY, OWNER_LOGIN
set -euo pipefail
pr=$1
r=$GITHUB_REPOSITORY
trusted='["coderabbitai[bot]","github-actions[bot]"]'

echo "## Review summaries"
gh api "repos/$r/pulls/$pr/reviews" --paginate | jq -r --arg o "$OWNER_LOGIN" --argjson t "$trusted" '
  .[] | select((.user.login == $o or (.user.login as $u | $t | index($u))) and (.body // "") != "")
  | "---\nFrom \(.user.login):\n\(.body)\n"'

echo "## Inline comments"
gh api "repos/$r/pulls/$pr/comments" --paginate | jq -r --arg o "$OWNER_LOGIN" --argjson t "$trusted" '
  .[] | select(.user.login == $o or (.user.login as $u | $t | index($u)))
  | "---\n\(.user.login) on \(.path):\(.line // .original_line // "?"):\n\(.body)\n"'

echo "## Conversation"
gh api "repos/$r/issues/$pr/comments" --paginate | jq -r --arg o "$OWNER_LOGIN" --argjson t "$trusted" '
  .[] | select((.user.login == $o or (.user.login as $u | $t | index($u)))
               and ((.body // "") | contains("<!-- agent-fix-round -->") | not))
  | "---\nFrom \(.user.login):\n\(.body)\n"'
