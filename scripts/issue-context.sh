#!/usr/bin/env bash
# Print an issue as Markdown for a prompt: title, body, and the OWNER's comments only.
# Other people's comments are dropped so they cannot steer the agent.
# Usage: issue-context.sh ISSUE_NUMBER      Env: GH_TOKEN, GITHUB_REPOSITORY, OWNER_LOGIN
#        ISSUE_JSON_OUT (optional): also save the accepted issue's JSON to this file
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
n=$1

issue=$(gh issue view "$n" -R "$GITHUB_REPOSITORY" --json number,title,body,author,labels,comments)

author=$(jq -r '.author.login' <<<"$issue")
if [[ "$author" != "$OWNER_LOGIN" ]]; then
  echo "::error::Issue #$n was opened by $author, not $OWNER_LOGIN. Refusing." >&2
  exit 1
fi
# A Release or Plan issue is filed as the owner but its body is commit text or model
# text (lib/meta.jq). It is never context for a dev, fix or review prompt.
if [[ $(jq -r -L "$here/lib" 'include "meta"; is_meta_issue' <<<"$issue") != false ]]; then
  echo "::error::Issue #$n is a Release or Plan issue filed by the loop. Refusing to use it as prompt context." >&2
  exit 1
fi
# Optional: keep the accepted issue for a caller that needs more than the Markdown
# (review-linked.sh). Written only after both checks above have passed.
if [[ -n "${ISSUE_JSON_OUT:-}" ]]; then printf '%s\n' "$issue" > "$ISSUE_JSON_OUT"; fi

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
