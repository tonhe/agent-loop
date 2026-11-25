#!/usr/bin/env bash
# File the out-of-scope problems the agent reported as new issues, as the owner.
# They go into normal triage (no routing label), tagged agent:found.
# Usage: file-found.sh SOURCE_ISSUE RESULT_JSON [PR_URL]
# Env:   GH_TOKEN (PAT), GITHUB_REPOSITORY, MAX_FOUND (default 3), DRY_RUN
# Prints one "- #N title" line per filed issue, "- skipped (dup): title" for duplicates.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
src=$1; result=$2; pr=${3:-}
max=${MAX_FOUND:-3}
repo=$GITHUB_REPOSITORY

[[ -s "$result" ]] || exit 0
count=$(jq '(.found_issues // []) | length' "$result")
(( count == 0 )) && exit 0

open_titles=$(gh issue list -R "$repo" --state open --limit 500 --json title --jq '[.[].title | ascii_downcase]')
filed=0
while read -r item; do
  (( filed >= max )) && { echo "- cap of $max reached; rest left in the run log"; break; }
  # The model wrote the title and the body: no Release/Plan look-alike title, no forged marker.
  title=$(jq -r -L "$here/lib" 'include "meta"; .title | safe_title | .[:200]' <<<"$item")
  if jq -e --arg t "$title" 'index($t | ascii_downcase) != null' <<<"$open_titles" >/dev/null; then
    echo "- skipped (dup): $title"; continue
  fi
  origin="Found by the dev agent while working #$src"
  [[ -n $pr ]] && origin+=" ($pr)"
  body="$origin.

$(jq -r -L "$here/lib" 'include "base"; include "meta"; .body | defang_base | defang_markers' <<<"$item")

<!-- agent-found from=$src -->"
  if [[ ${DRY_RUN:-false} == true ]]; then
    echo "- DRY: $title"
  else
    url=$(gh issue create -R "$repo" --title "$title" --body "$body" --label agent:found)
    echo "- ${url##*/issues/} $title"
  fi
  filed=$((filed + 1))
  open_titles=$(jq -c --arg t "$title" '. + [$t | ascii_downcase]' <<<"$open_titles")
done < <(jq -c '.found_issues[]' "$result")
