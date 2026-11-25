#!/usr/bin/env bash
# May a work-issue subagent go on with the changes in this worktree? Run it before
# opening a PR, and whenever the work turns towards a file the issue did not name.
# Checks every changed path (committed since BASE, staged, unstaged and untracked):
#   protected  matches protected_paths: never changed by an agent (check-diff.sh)
#   process    the loop's own process files (.github/, CLAUDE.md, ...; lib/merge-gate.jq)
#   needs_decision  matches protected_review_paths and issue ISSUE has no Owner decision
# On any of them the subagent stops: claim-issue.sh stop ISSUE "<what is needed>".
# Settings come from the caller workflows on BASE (loop-config.sh).
# Usage: scope-check.sh ISSUE BASE        (in the issue's worktree)
# Env:   GITHUB_REPOSITORY (default: current repo)
# Out:   JSON {ok, protected, process, needs_decision, decision_scope}
# Exit:  0 ok, 1 stop, 2 usage error.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
n=${1:-}; base=${2:-}
[[ "$n" =~ ^[1-9][0-9]{0,8}$ && -n "$base" ]] || { echo "usage: scope-check.sh ISSUE BASE" >&2; exit 2; }
jq -en -L "$here/lib" --arg b "$base" 'include "base"; $b | valid_ref' >/dev/null || { echo "scope-check: bad base" >&2; exit 2; }
repo=${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}
export GITHUB_REPOSITORY=$repo
cfg=$(bash "$here/scripts/loop-config.sh" "$base")
owner=$(jq -r .owner_login <<<"$cfg")

git fetch -q origin "$base" 2>/dev/null || true
mb=$(git merge-base HEAD "origin/$base" 2>/dev/null || git merge-base HEAD "$base")
files=$( { git -c core.quotePath=false diff -z --name-only --no-renames "$mb"
           git ls-files -z --others --exclude-standard; } | jq -Rs 'split("\u0000") | map(select(. != "")) | unique')
mapfile -t specs < <(jq -r .protected_paths <<<"$cfg" | sed '/^[[:space:]]*$/d')
hits=$(bash "$here/scripts/pathspec-hits.sh" "${specs[@]}" <<<"$files")
comments=$(gh issue view "$n" -R "$repo" --json comments --jq .comments)
res=$(jq -n -L "$here/lib" --argjson f "$files" --argjson h "$hits" --argjson c "$comments" \
        --arg owner "$owner" --arg globs "$(jq -r .protected_review_paths <<<"$cfg")" \
        'include "sprint"; {files: $f, protected_hits: $h, comments: $c} | scope_check($owner; $globs)')
echo "$res"
[[ $(jq -r .ok <<<"$res") == true ]]
