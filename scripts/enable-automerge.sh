#!/usr/bin/env bash
# Turn on squash auto-merge for a PR, but only if the base branch has a ruleset
# requiring status checks with nobody allowed to bypass. Without that, GitHub would
# merge immediately, so this refuses.
# Usage: enable-automerge.sh PR      Env: GH_TOKEN (PAT), GITHUB_REPOSITORY, BASE_BRANCH
set -euo pipefail
pr=$1
rules=$(gh api "repos/$GITHUB_REPOSITORY/rules/branches/$BASE_BRANCH")

if ! jq -e 'any(.[]; .type == "required_status_checks")' <<<"$rules" >/dev/null; then
  echo "::error::$BASE_BRANCH has no required status checks. Refusing to enable auto-merge."
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
