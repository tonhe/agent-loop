#!/usr/bin/env bash
# Print GitHub's native issue dependencies for every open issue, as the $native map
# lib/blocked.jq expects: {"<issue number>": [numbers of its OPEN blockers]}.
# One paginated GraphQL query covers all open issues (issue.blockedBy).
# If the dependencies API is unavailable or the answer is unusable, this prints {} with
# a warning rather than failing: the run goes on with prose "Blocked by #N" only.
# Usage: native-blockers.sh      Env: GH_TOKEN, GITHUB_REPOSITORY
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
owner=${GITHUB_REPOSITORY%%/*}
name=${GITHUB_REPOSITORY#*/}

# shellcheck disable=SC2016  # GraphQL variables, not shell
query='query($owner: String!, $name: String!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    issues(states: OPEN, first: 100, after: $endCursor) {
      pageInfo { hasNextPage endCursor }
      nodes { number blockedBy(first: 50) { totalCount nodes { number state } } }
    }
  }
}'

if pages=$(gh api graphql --paginate -f query="$query" -f owner="$owner" -f name="$name") \
   && map=$(jq -cs -f "$here/lib/native-blockers.jq" <<<"$pages"); then
  printf '%s\n' "$map"
else
  echo "::warning::Could not read native issue dependencies; only \"Blocked by #N\" text is honoured in this run." >&2
  echo '{}'
fi
