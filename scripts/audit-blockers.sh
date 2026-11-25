#!/usr/bin/env bash
# Blocker audit: compare the blockers written in each open issue ("Blocked by #N") with
# GitHub's native dependencies, add the native link where only the text has it, and
# report the rest. The decision is made by lib/audit-blockers.jq (audit_plan); this
# script fetches, applies and prints. No model is involved.
#
# The only write it ever makes is
#   POST repos/{repo}/issues/{issue}/dependencies/blocked_by   issue_id=<blocker's database id>
# It never removes a dependency, never edits an issue body and never touches an issue
# that is not the owner's. It reads with its own query, so whatever happens here changes
# nothing in what selection and triage see (native-blockers.sh).
#
# Usage: audit-blockers.sh [WORK_DIR]
# Env:   GH_TOKEN (the PAT), GITHUB_REPOSITORY, OWNER_LOGIN,
#        AUDIT_MODE (fix | report | off; default fix; anything else is taken as report),
#        MAX_LINKS (most links added per run, default 10), DRY_RUN (true|false)
# Prints the text for the digest: nothing at all when text and links agree. Issues are
# written as #N, never as a URL. Everything else (gh output, the plan, warnings) goes to
# stderr, the job log. Writes WORK_DIR/audit-plan.json.
# An API failure is a warning and exit 0: the audit is a convenience, not a gate.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
repo=$GITHUB_REPOSITORY
owner=${OWNER_LOGIN:?}
mode=${AUDIT_MODE:-fix}
max=${MAX_LINKS:-10}
dry=${DRY_RUN:-false}
lines=15   # detail lines in the digest; Discord caps a message at 2000 characters

[[ "$max" =~ ^[0-9]+$ ]] || { echo "::error::MAX_LINKS must be a number" >&2; exit 1; }
case "$mode" in
  off) exit 0 ;;
  fix|report) ;;
  *) echo "::warning::Unknown AUDIT_MODE; the blocker audit only reports in this run." >&2; mode=report ;;
esac
w=${1:-$(mktemp -d)}; mkdir -p "$w"

# shellcheck disable=SC2016  # GraphQL variables, not shell
query='query($owner: String!, $name: String!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    issues(states: OPEN, first: 100, after: $endCursor) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number fullDatabaseId body author { login }
        blockedBy(first: 50) { totalCount nodes { number state repository { nameWithOwner } } }
      }
    }
  }
}'

# Issue bodies only ever travel through files and jq: nothing here evaluates them.
if ! { gh api graphql --paginate -f query="$query" -f owner="${repo%%/*}" -f name="${repo#*/}" > "$w/audit-pages.json" \
       && jq -s -L "$here/lib" --arg repo "$repo" --arg owner "$owner" --argjson max "$max" \
            'include "audit-blockers"; audit_issues($repo) | audit_plan($owner; $max)' \
            "$w/audit-pages.json" > "$w/audit-plan.json"; }; then
  echo "::warning::Blocker audit could not read the issues and their dependencies; nothing was checked or changed." >&2
  echo "Blocker audit: could not read the issues and their dependencies; nothing was checked or changed."
  exit 0
fi
rm -f "$w/audit-pages.json"
{ echo "Blocker audit plan (mode $mode, dry run $dry, at most $max links):"; jq -c . "$w/audit-plan.json"; } >&2

: > "$w/audit-results.jsonl"
while read -r issue blocker id; do
  # Built by jq from numbers only; checked again because they go on a command line.
  [[ "$issue" =~ ^[1-9][0-9]*$ && "$blocker" =~ ^[1-9][0-9]*$ && "$id" =~ ^[1-9][0-9]*$ ]] \
    || { echo "::warning::Blocker audit: unexpected plan entry skipped." >&2; continue; }
  if [[ "$mode" != fix ]]; then status=report
  elif [[ "$dry" == true ]]; then status=dry
  # The answer is the whole blocked issue, URLs included: to the job log, not the digest.
  elif gh api -X POST "repos/$repo/issues/$issue/dependencies/blocked_by" -F issue_id="$id" </dev/null >&2; then status=added
  else
    status=failed
    echo "::warning::Blocker audit: could not add the link from #$issue to #$blocker." >&2
  fi
  printf '{"issue":%s,"blocker":%s,"status":"%s"}\n' "$issue" "$blocker" "$status" >> "$w/audit-results.jsonl"
done < <(jq -r '.add[] | "\(.issue) \(.blocker) \(.id)"' "$w/audit-plan.json")

# Links may have been added by now, so a failure to word the text must not hide that.
if text=$(jq -rs -L "$here/lib" --slurpfile plan "$w/audit-plan.json" --argjson max "$max" --argjson lines "$lines" \
            'include "audit-blockers"; {plan: $plan[0], results: .} | audit_text($max; $lines)' "$w/audit-results.jsonl"); then
  if [[ -n "$text" ]]; then printf '%s\n' "$text"; fi
else
  echo "::warning::Blocker audit: could not word its report; the plan and each link are in the log above." >&2
  echo "Blocker audit: ran, but its report could not be written; see the run log."
fi
