#!/usr/bin/env bash
# Release mode or maintenance mode (lib/release-mode.jq, #61). Changes nothing on GitHub.
# Usage: release-mode.sh
# Env:   GH_TOKEN, GITHUB_REPOSITORY
# Out:   {"mode": "release" | "maintenance", "approved": [{"number": N, "title": "..."}]}
# When the milestones cannot be read the answer is maintenance, with a warning: a
# feature is then neither marked ready nor picked, which is the safe side.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
repo=${GITHUB_REPOSITORY:?}
if ! ms=$(gh api "repos/$repo/milestones?state=open&per_page=100" \
            --jq '[.[] | {number, title, description}]'); then
  echo "::warning::Could not list milestones; treating the repository as in maintenance mode for this run." >&2
  ms='[]'
fi
jq -c -L "$here/lib" 'include "release-mode"; release_mode' <<<"$ms"
