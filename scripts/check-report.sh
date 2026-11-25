#!/usr/bin/env bash
# Accept or reject a work-issue subagent's report (lib/sprint.jq, report_problems).
# Rejected: a noted problem with no filed issue URL, pr_opened without a PR URL, a bare
# #N anywhere (use full https://github.com/owner/repo/... URLs), a stopped report
# without a reason, a live check without its commands.
# Usage: check-report.sh REPORT_JSON     Env: GITHUB_REPOSITORY (default: current repo)
# Exit:  0 accepted, 1 rejected (problems listed), 2 not JSON.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
f=${1:?usage: check-report.sh REPORT_JSON}
repo=${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}
jq -e 'type == "object"' "$f" >/dev/null 2>&1 || { echo "report: REJECTED: not a JSON object" >&2; exit 2; }
problems=$(jq -r -L "$here/lib" --arg repo "$repo" 'include "sprint"; report_problems($repo)[]' "$f")
if [[ -n "$problems" ]]; then
  echo "report: REJECTED"
  while IFS= read -r p; do printf '  - %s\n' "$p"; done <<<"$problems"
  exit 1
fi
echo "report: accepted"
