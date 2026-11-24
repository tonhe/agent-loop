#!/usr/bin/env bash
# Turn on squash auto-merge for a PR, but only if the base branch has a ruleset
# requiring status checks with nobody allowed to bypass. Without that, GitHub would
# merge immediately, so this refuses.
# The base branch is the PR's own (it may be a per-issue base), never an assumed default.
# Usage: enable-automerge.sh PR      Env: GH_TOKEN (PAT), GITHUB_REPOSITORY
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
pr=$1
base=$(gh pr view "$pr" -R "$GITHUB_REPOSITORY" --json baseRefName --jq .baseRefName)
if ! jq -en -L "$here/lib" --arg b "$base" 'include "base"; $b | valid_ref' >/dev/null; then
  echo "::error::PR #$pr has a base branch that is not a plain branch name. Refusing to enable auto-merge."
  exit 1
fi
rules=$(gh api "repos/$GITHUB_REPOSITORY/rules/branches/$base")

if ! jq -e 'any(.[]; .type == "required_status_checks")' <<<"$rules" >/dev/null; then
  echo "::error::$base has no required status checks. Refusing to enable auto-merge."
  exit 1
fi

# Rulesets the PAT can bypass make the checks meaningless. Look for bypass actors.
ids=$(jq -r '[.[] | .ruleset_id] | unique | .[]' <<<"$rules")
for id in $ids; do
  bypass=$(gh api "repos/$GITHUB_REPOSITORY/rulesets/$id" --jq '.bypass_actors | length' 2>/dev/null || echo "unknown")
  if [[ $bypass != "0" ]]; then
    echo "::error::Ruleset $id has bypass actors ($bypass). Remove them, or auto-merge would not be gated."
    exit 1
  fi
done

gh pr merge "$pr" -R "$GITHUB_REPOSITORY" --auto --squash
echo "Auto-merge enabled for #$pr"
