#!/usr/bin/env bash
# Owner-mode review: the issues an owner PR links, as prompt context.
#
# The PR body may be model text (the owner's interactive agent wrote it), so only issue
# numbers are taken from it: "Fixes|Closes|Resolves|Refs #N" (lib/review.jq, linked_issues),
# this repository only, at most 5. Each number then goes through issue-context.sh, which
# is what decides whether an issue may be shown to the model: it must be opened by
# OWNER_LOGIN and must not be a Release or Plan issue, and only the owner's comments are
# printed. An issue it refuses, or one that cannot be read, is skipped with a log line.
#
# Usage: review-linked.sh OUT_DIR
# Env:   BODY (the PR body), GH_TOKEN, GITHUB_REPOSITORY, OWNER_LOGIN
# Writes OUT_DIR/issues.md    the "Issue" section of the review prompt
#        OUT_DIR/used.json    [numbers] of the issues in it
#        OUT_DIR/linked.json  [{number, comments}] of those issues, for review-protected.sh
# Exit:  0, also when nothing usable is linked (the PR is then reviewed on its diff alone).
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
out=$1
mkdir -p "$out"
: "${OWNER_LOGIN:?}" "${GITHUB_REPOSITORY:?}"

numbers=$(printf '%s' "${BODY:-}" | jq -Rs -r -L "$here/lib" 'include "review"; linked_issues[]')

: > "$out/issues.md"
echo '[]' > "$out/linked.json"
for n in $numbers; do
  # linked_issues only returns numbers; checked again because $n becomes an argument.
  [[ "$n" =~ ^[1-9][0-9]{0,8}$ ]] || continue
  if ISSUE_JSON_OUT="$out/issue.json" bash "$here/scripts/issue-context.sh" "$n" > "$out/issue.md" 2> "$out/issue.err"; then
    { cat "$out/issue.md"; echo; } >> "$out/issues.md"
    jq -s '.[0] + [.[1] | {number, comments: (.comments // [])}]' "$out/linked.json" "$out/issue.json" > "$out/linked.tmp"
    mv "$out/linked.tmp" "$out/linked.json"
    echo "Linked issue #$n: used as review context."
  else
    # issue-context.sh words its refusal as an error annotation. Here a refusal is the
    # expected outcome for someone else's issue, so only the reason is logged.
    reason=$(head -1 "$out/issue.err" | sed 's/^::error:://' | tr -d '\r' | cut -c1-200)
    echo "Linked issue #$n skipped: ${reason:-could not be read}"
  fi
  rm -f "$out/issue.md" "$out/issue.err" "$out/issue.json"
done

jq -c 'map(.number)' "$out/linked.json" > "$out/used.json"
if [[ ! -s "$out/issues.md" ]]; then
  {
    echo "(No linked issue. The PR body names no issue opened by the owner with \`Fixes #N\`, \`Closes #N\`, \`Resolves #N\` or \`Refs #N\`. Review the diff on its own.)"
  } > "$out/issues.md"
  echo "No usable linked issue: the PR is reviewed on its diff alone."
fi
