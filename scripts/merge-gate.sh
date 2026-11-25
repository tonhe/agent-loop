#!/usr/bin/env bash
# The only way a sprint agent merges: check a loop PR against every rule, and only then
# turn on auto-merge (enable-automerge.sh). GitHub still merges only when the ruleset's
# required checks pass; this gate adds the rules a ruleset cannot express.
#
# Refuses (exit 1, one line per reason) unless all of these hold:
#   - the PR is an open, non-draft loop PR: opened by the owner from this repository, head
#     branch issue-N, body marker agreeing (lib/pr.jq)
#   - issue N is open, the owner's, not a Release or Plan issue, and not needs:human
#   - every required status check of the base branch's rulesets succeeded on the head
#     commit (pending, missing, skipped, neutral and failed all refuse)
#   - no file matches protected_paths (git pathspecs, as check-diff.sh) or the loop's
#     process paths (.github/, .claude/, CLAUDE.md, RELEASING.md, ...), and none matches
#     protected_review_paths unless issue N has an Owner decision comment
#   - a PR labeled agent:live-check has the owner's "Live check passed <head sha>" comment
#   - no merge conflict, and the head is up to date when the ruleset requires it
#   - the repository is not agent-loop itself
# Settings come from the caller workflows on the PR's base branch (loop-config.sh), so a
# PR cannot loosen the rules it is checked against. Any error reading GitHub refuses.
# The decision is lib/merge-gate.jq (merge_gate).
#
# Usage: merge-gate.sh PR [--check]     --check: decide and print, never enable auto-merge
# Env:   GITHUB_REPOSITORY (default: the current directory's repo), LOOP_REPO (default
#        tonhe/agent-loop), DEV_CALLER, REVIEW_CALLER (see loop-config.sh)
# Exit:  0 allowed (and auto-merge enabled unless --check), 1 refused, 2 usage error.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
pr=${1:-}
check_only=false
[[ "${2:-}" == --check ]] && check_only=true
[[ "$pr" =~ ^[1-9][0-9]{0,8}$ ]] || { echo "usage: merge-gate.sh PR [--check]" >&2; exit 2; }
repo=${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}
export GITHUB_REPOSITORY=$repo
loop_repo=${LOOP_REPO:-tonhe/agent-loop}
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
trap 'echo "merge-gate: REFUSED #$pr: a step failed (line $LINENO); nothing was enabled" >&2' ERR

gh pr view "$pr" -R "$repo" \
  --json number,state,isDraft,isCrossRepository,author,headRefName,headRefOid,baseRefName,body,mergeable,labels,comments \
  > "$work/pr.json"
base=$(jq -r .baseRefName "$work/pr.json")
sha=$(jq -r .headRefOid "$work/pr.json")
jq -en -L "$here/lib" --arg b "$base" 'include "base"; $b | valid_ref' >/dev/null \
  || { echo "merge-gate: REFUSED #$pr: base branch is not a plain branch name" >&2; exit 1; }
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "merge-gate: REFUSED #$pr: head commit is unknown" >&2; exit 1; }

bash "$here/scripts/loop-config.sh" "$base" > "$work/config.json"
owner=$(jq -r .owner_login "$work/config.json")

n=$(jq -r -L "$here/lib" 'include "pr"; branch_issue // ""' "$work/pr.json")
if [[ -n "$n" ]]; then
  gh issue view "$n" -R "$repo" --json number,state,author,body,labels,comments > "$work/issue.json"
else
  echo null > "$work/issue.json"
fi

# Every path the PR touches, both sides of a rename. The API lists at most 3000 files;
# a list shorter than changed_files refuses (files_complete below).
changed=$(gh api "repos/$repo/pulls/$pr" --jq .changed_files)
gh api --paginate "repos/$repo/pulls/$pr/files?per_page=100" \
  --jq '[.[] | .filename, (.previous_filename // empty)]' | jq -s 'add // []' > "$work/files.json"
listed=$(gh api --paginate "repos/$repo/pulls/$pr/files?per_page=100" --jq '.[].filename' | wc -l)

# protected_paths are git pathspecs, matched by git itself (the same test as check-diff.sh).
mapfile -t specs < <(jq -r .protected_paths "$work/config.json" | sed '/^[[:space:]]*$/d')
bash "$here/scripts/pathspec-hits.sh" "${specs[@]}" < "$work/files.json" > "$work/hits.json"

gh api "repos/$repo/rules/branches/$base" > "$work/rules.json"
gh api --paginate "repos/$repo/commits/$sha/check-runs?per_page=100" \
  --jq '[.check_runs[] | {id, name, status, conclusion}]' | jq -s 'add // [] | sort_by(-.id)' > "$work/checks.json"
gh api --paginate "repos/$repo/commits/$sha/statuses?per_page=100" \
  --jq '[.[] | {id, context, state}]' | jq -s 'add // [] | sort_by(-.id)' > "$work/statuses.json"
behind=$(gh api "repos/$repo/compare/$base...$sha" --jq .behind_by)

is_loop=false
[[ "${repo,,}" == "${loop_repo,,}" ]] && is_loop=true

jq -n --arg owner "$owner" --argjson loop "$is_loop" \
      --slurpfile pr "$work/pr.json" --slurpfile issue "$work/issue.json" \
      --slurpfile files "$work/files.json" --slurpfile hits "$work/hits.json" \
      --slurpfile cfg "$work/config.json" --slurpfile rules "$work/rules.json" \
      --slurpfile checks "$work/checks.json" --slurpfile statuses "$work/statuses.json" \
      --argjson behind "$behind" --argjson changed "$changed" --argjson listed "$listed" '
  {owner: $owner, is_loop_repo: $loop, pr: $pr[0], issue: $issue[0], files: $files[0],
   files_complete: ($listed >= $changed), protected_hits: $hits[0],
   protected_review_paths: $cfg[0].protected_review_paths, rules: $rules[0],
   checks: $checks[0], statuses: $statuses[0], behind_by: $behind}' > "$work/facts.json"
jq -L "$here/lib" 'include "merge-gate"; merge_gate' "$work/facts.json" > "$work/decision.json"
trap - ERR

if [[ $(jq -r .ok "$work/decision.json") != true ]]; then
  echo "merge-gate: REFUSED https://github.com/$repo/pull/$pr"
  jq -r '.reasons[] | "  - \(.)"' "$work/decision.json"
  echo "Left for the owner. Nothing was enabled."
  exit 1
fi

if $check_only; then
  echo "merge-gate: ALLOWED https://github.com/$repo/pull/$pr (--check: auto-merge not enabled)"
  exit 0
fi
echo "merge-gate: ALLOWED https://github.com/$repo/pull/$pr; enabling auto-merge"
MERGE_GATE_PASSED=1 bash "$here/scripts/enable-automerge.sh" "$pr"
