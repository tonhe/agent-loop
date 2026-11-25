#!/usr/bin/env bash
# Review check for protected-by-instruction paths (review input protected_review_paths).
# When the PR changes a file matching one of the globs, the linked issue must carry a
# comment from the owner that begins with "Owner decision" and names the approved scope.
#   - no such comment: this script blocks the review itself. It posts a comment listing
#     the files and exits 1. The model is not involved.
#   - a comment exists: it writes OUT_DIR/section.md (matched files plus the owner's
#     decision text) for the review prompt; the model judges whether the diff stays in scope.
# Glob syntax and the decision are in lib/glob.jq (review_protected).
#
# MODE=owner (an owner PR, see review-gate.sh) is a different rule. The PR body may be
# model text and chooses the linked issues, so an "Owner decision" comment there is never
# an approval: nothing is blocked, nothing is suppressed, no comment is posted here and
# GitHub is not called. The script writes OUT_DIR/owner-section.md: every protected file
# the PR changes, and next to them the owner's "Owner decision" comments found on the
# linked issues review-linked.sh accepted (LINKED_JSON), or a line saying there is none.
# review-post.sh puts that section into the posted review as it is (lib/glob.jq,
# owner_protected). The changed-file list is the same one in both modes.
#
# Usage: review-protected.sh ISSUE PR OUT_DIR       (run in the PR checkout; ISSUE is
#                                                    ignored when MODE=owner)
# Env:   GH_TOKEN, GITHUB_REPOSITORY, OWNER_LOGIN, BASE_SHA,
#        PROTECTED_REVIEW_PATHS (newline-separated globs; empty = feature off)
#        MODE (loop, the default, or owner), LINKED_JSON (owner mode: review-linked.sh's
#        linked.json; missing or unreadable counts as no linked issue)
# Writes OUT_DIR/result.json {status, matched, decisions}.
# Exit:  0 off / nothing protected changed / scope left to the model, 1 blocked.
#        MODE=owner: 0 whatever was found.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
issue=$1; pr=$2; out=$3
mode=${MODE:-loop}
mkdir -p "$out"
globs=${PROTECTED_REVIEW_PATHS:-}

if [[ -z "${globs//[[:space:]]/}" ]]; then
  echo '{"status":"off","matched":[],"decisions":[]}' > "$out/result.json"
  echo "Protected review paths: none configured."
  exit 0
fi
[[ "$mode" == loop || "$mode" == owner ]] || { echo "::error::MODE must be loop or owner" >&2; exit 1; }
if [[ "$mode" == loop ]]; then
  [[ "$issue" =~ ^[0-9]+$ && "$pr" =~ ^[0-9]+$ ]] || { echo "::error::Need an issue and a PR number" >&2; exit 1; }
fi
[[ "${BASE_SHA:-}" =~ ^[0-9a-f]{7,64}$ ]] || { echo "::error::BASE_SHA is not a commit id" >&2; exit 1; }

# --no-renames: a file moved out of a protected directory shows up as a deletion there.
# quotePath=false keeps non-ASCII names readable; names with quotes, backslashes or
# control characters are still printed C-quoted, and lib/glob.jq counts those as protected.
git -c core.quotePath=false diff --name-only --no-renames "$BASE_SHA"...HEAD > "$out/files.txt"

if [[ "$mode" == owner ]]; then
  linked='[]'
  if [[ -n "${LINKED_JSON:-}" && -f "$LINKED_JSON" ]] && jq -e 'type == "array"' "$LINKED_JSON" >/dev/null 2>&1; then
    linked=$(jq -c . "$LINKED_JSON")
  fi
  jq -Rn '[inputs | select(. != "")]' < "$out/files.txt" > "$out/files.json"
  jq -n --slurpfile f "$out/files.json" --argjson i "$linked" '{files: $f[0], issues: $i}' \
    | jq -L "$here/lib" --arg globs "$globs" --arg owner "$OWNER_LOGIN" \
        'include "glob"; owner_protected($globs; $owner)' > "$out/result.json"
  if [[ $(jq -r .status "$out/result.json") == listed ]]; then
    jq -r -L "$here/lib" 'include "glob"; owner_protected_section' "$out/result.json" > "$out/owner-section.md"
    echo "Protected review paths: $(jq '.matched | length') protected file(s) changed, $(jq '.decisions | length' "$out/result.json") Owner decision comment(s) on linked issues. Listed in the review for the owner; nothing is blocked on an owner PR." < "$out/result.json"
  else
    echo "Protected review paths: no protected file is changed."
  fi
  exit 0
fi

# Same owner filtering as issue-context.sh: the issue must be the owner's, and only the
# owner's comments are looked at.
gh issue view "$issue" -R "$GITHUB_REPOSITORY" --json author,comments > "$out/issue.json"
author=$(jq -r '.author.login' "$out/issue.json")
if [[ "$author" != "$OWNER_LOGIN" ]]; then
  echo "::error::Issue #$issue was opened by $author, not $OWNER_LOGIN. Refusing." >&2
  exit 1
fi

jq -Rn '[inputs | select(. != "")]' < "$out/files.txt" > "$out/files.json"
jq -n --slurpfile f "$out/files.json" --slurpfile i "$out/issue.json" '{files: $f[0], comments: $i[0].comments}' \
  | jq -L "$here/lib" --arg globs "$globs" --arg owner "$OWNER_LOGIN" \
      'include "glob"; review_protected($globs; $owner)' > "$out/result.json"

status=$(jq -r .status "$out/result.json")
# File names come from the PR: shown in code spans, with backticks replaced.
list=$(jq -r '.matched[] | "- `\(.file | gsub("`"; "'"'"'"))` (protected by `\(.glob | gsub("`"; "'"'"'"))`)"' "$out/result.json")

case "$status" in
  clear)
    echo "Protected review paths: no protected file is changed."
    ;;
  no_decision)
    {
      echo "<!-- agent-review -->"
      echo "### Agent review: BLOCK"
      echo
      echo "This PR changes files that are protected by instruction, and issue #$issue has no comment from the owner that begins with \`Owner decision\` and names the approved scope."
      echo
      echo "$list"
      echo
      echo "To allow the change: comment on #$issue starting with \`Owner decision\` and say what may change in these files, then re-run this check. Otherwise take these files out of the PR."
    } > "$out/comment.md"
    gh pr comment "$pr" -R "$GITHUB_REPOSITORY" --body-file "$out/comment.md" >/dev/null
    [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && cat "$out/comment.md" >> "$GITHUB_STEP_SUMMARY"
    echo "::error::Protected files changed without an Owner decision comment on #$issue"
    exit 1
    ;;
  check_scope)
    {
      echo "## Protected paths"
      echo
      echo "This PR changes files the owner protects by instruction. They may change only within the scope the owner approved in the \"Owner decision\" comment(s) on the issue."
      echo
      echo "Protected files changed:"
      echo "$list"
      echo
      echo "Owner decision comment(s):"
      jq -r '.decisions[] | "---\n\(.)\n"' "$out/result.json"
      echo "---"
    } > "$out/section.md"
    echo "Protected review paths: $(jq '.matched | length' "$out/result.json") protected file(s) changed; an Owner decision comment exists, scope goes to the reviewer."
    ;;
  *) echo "::error::unexpected status $status" >&2; exit 1 ;;
esac
