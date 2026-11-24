#!/usr/bin/env bash
# Print an issue as Markdown for a prompt: title, body, and the OWNER's comments only.
# Other people's comments are dropped so they cannot steer the agent.
# Usage: issue-context.sh ISSUE_NUMBER      Env: GH_TOKEN, GITHUB_REPOSITORY, OWNER_LOGIN
set -euo pipefail
n=$1

issue=$(gh issue view "$n" -R "$GITHUB_REPOSITORY" --json number,title,body,author,labels,comments)

author=$(jq -r '.author.login' <<<"$issue")
if [[ "$author" != "$OWNER_LOGIN" ]]; then
  echo "::error::Issue #$n was opened by $author, not $OWNER_LOGIN. Refusing." >&2
  exit 1
fi

jq -r --arg owner "$OWNER_LOGIN" '
  "### #\(.number): \(.title)\n",
  "Labels: \([.labels[].name] | join(", "))\n",
  "\(.body // "(no body)")\n",
  ([.comments[] | select(.author.login == $owner)] as $c
   | if ($c | length) > 0 then
       "### Owner comments\n",
       ($c[] | "---\n\(.body)\n")
     else empty end),
  ([.comments[] | select(.author.login != $owner)] | length) as $other
  | if $other > 0 then "\n(\($other) comment(s) from other people were omitted.)" else empty end
' <<<"$issue"
