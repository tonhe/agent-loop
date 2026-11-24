#!/usr/bin/env bash
# Reject the agent's working-tree changes if they touch protected paths.
# Usage: check-diff.sh            Env: PROTECTED_PATHS (newline-separated git pathspecs)
# Always protected: .github/  (the PAT cannot push workflow changes anyway)
# Exit 0 = changes present and allowed, 2 = no changes, 1 = protected path touched.
set -euo pipefail

git add -A
changed=$(git diff --cached --name-only)
if [[ -z "$changed" ]]; then
  echo "No changes."
  exit 2
fi
echo "Changed files:"; sed 's/^/  /' <<<"$changed"

mapfile -t specs < <(printf '%s\n' ".github/" "${PROTECTED_PATHS:-}" | sed '/^[[:space:]]*$/d')
bad=$(git diff --cached --name-only -- "${specs[@]}" || true)
if [[ -n "$bad" ]]; then
  echo "::error::Agent touched protected paths:"; sed 's/^/  /' <<<"$bad"
  exit 1
fi
