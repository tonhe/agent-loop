#!/usr/bin/env bash
# Print GitHub's native sub-issue links for every open issue, as the $parents map
# lib/paired.jq expects: {"<issue number>": number of its parent issue}.
# One paginated GraphQL query covers all open issues (issue.parent). It is a separate
# query from native-blockers.sh on purpose: if this one fails, blockers still work.
# If the sub-issues API is unavailable or the answer is unusable, this prints {} with a
# warning rather than failing: the run goes on with "Part of #N" lines only.
# Usage: native-parents.sh      Env: GH_TOKEN, GITHUB_REPOSITORY
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
owner=${GITHUB_REPOSITORY%%/*}
name=${GITHUB_REPOSITORY#*/}

# shellcheck disable=SC2016  # GraphQL variables, not shell
query='query($owner: String!, $name: String!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    issues(states: OPEN, first: 100, after: $endCursor) {
      pageInfo { hasNextPage endCursor }
      nodes { number parent { number repository { nameWithOwner } } }
    }
  }
}'

if pages=$(gh api graphql --paginate -f query="$query" -f owner="$owner" -f name="$name") \
   && map=$(jq -cs --arg repo "$GITHUB_REPOSITORY" -f "$here/lib/native-parents.jq" <<<"$pages"); then
  printf '%s\n' "$map"
else
  echo "::warning::Could not read native sub-issue links; only \"Part of #N\" lines mark a sub-issue of an agent:paired epic in this run." >&2
  echo '{}'
fi
