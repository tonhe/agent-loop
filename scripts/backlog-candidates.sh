#!/usr/bin/env bash
# Gather the owner's issues that need (re)assessment, plus a count of external issues.
# Usage: backlog-candidates.sh OUT_DIR
# Writes: candidates.json (sent to Claude), external.json (digest only, never sent to Claude)
# Env:   GH_TOKEN, GITHUB_REPOSITORY, OWNER_LOGIN, MAX_CANDIDATES
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
out=$1; mkdir -p "$out"

gh issue list -R "$GITHUB_REPOSITORY" --state open --limit 200 \
  --json number,title,body,labels,author,createdAt,comments > "$out/all.json"

jq --arg owner "$OWNER_LOGIN" --argjson max "${MAX_CANDIDATES:-25}" \
   -f "$here/lib/candidates.jq" "$out/all.json" > "$out/candidates.json"

# External issues: numbers and authors only. Titles are untrusted and stay out of the digest too.
jq --arg owner "$OWNER_LOGIN" \
   '[.[] | select(.author.login != $owner) | {number, author: .author.login}]' \
   "$out/all.json" > "$out/external.json"

jq '[.[] | {key: (.number | tostring), value: [.labels[].name]}] | from_entries' \
   "$out/all.json" > "$out/current-labels.json"

echo "Candidates: $(jq length "$out/candidates.json"), external open issues: $(jq length "$out/external.json")"
