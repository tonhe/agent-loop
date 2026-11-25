#!/usr/bin/env bash
# Post the review and decide the check.
#
# Reads what the earlier steps left in WORK_DIR, builds ONE comment (lib/review.jq,
# review_combine) and posts it with the workflow's own token, so it shows as
# github-actions[bot], not as the owner.
#
#   loop   a new comment per run, as before. Exit 1 unless every group was reviewed and
#          the verdict is pass.
#   owner  advisory: the comment says so, and the exit is 0 whatever the verdict, also
#          when a call failed, timed out or returned something that is not a review (the
#          comment then says the review could not be completed, with a warning). One
#          comment per PR: the bot's earlier comment carrying the owner marker is updated
#          in place (lib/review.jq, existing_review_comment); only if there is none is a
#          new one created.
#
# Usage: review-post.sh WORK_DIR PR
# Env:   MODE (loop|owner), GH_TOKEN, GITHUB_REPOSITORY, HEAD_SHA (optional),
#        GITHUB_STEP_SUMMARY (optional)
# Reads  WORK_DIR/plan.json                   the split plan (review-prompts.sh)
#        WORK_DIR/groups/N/rc                 run-claude.sh's exit code for group N
#        WORK_DIR/groups/N/result.json        its structured result
#        WORK_DIR/groups/N/truncated          present when that group's diff was cut
#        WORK_DIR/protected/owner-section.md  owner mode (review-protected.sh)
#        WORK_DIR/linked/used.json            owner mode (review-linked.sh)
# Any of them may be missing: a missing piece makes the review incomplete, not a pass.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
work=$1; pr=$2
mode=${MODE:-loop}
[[ "$mode" == loop || "$mode" == owner ]] || { echo "::error::MODE must be loop or owner" >&2; exit 1; }
[[ "$pr" =~ ^[0-9]+$ ]] || { echo "::error::Need a PR number" >&2; exit 1; }
: "${GITHUB_REPOSITORY:?}"
mkdir -p "$work"

plan=null
if [[ -f "$work/plan.json" ]] && jq -e '.groups | type == "array"' "$work/plan.json" >/dev/null 2>&1; then
  plan=$(jq -c '.groups |= map(del(.paths))' "$work/plan.json")
fi
n=$(jq -n --argjson p "$plan" '$p.groups // [] | length')

: > "$work/calls.jsonl"
for ((i = 0; i < n; i++)); do
  d="$work/groups/$i"
  rc=""; [[ -f "$d/rc" ]] && rc=$(head -c 16 "$d/rc" | tr -cd '0-9')
  res=/dev/null; [[ -f "$d/result.json" ]] && res="$d/result.json"
  cut=false; [[ -e "$d/truncated" ]] && cut=true
  jq -n -c --arg rc "$rc" --rawfile r "$res" --argjson t "$cut" \
    '{rc: $rc, result: (try ($r | fromjson) catch null), truncated: $t}' >> "$work/calls.jsonl"
done

protected=/dev/null; linked=null
if [[ "$mode" == owner ]]; then
  [[ -f "$work/protected/owner-section.md" ]] && protected="$work/protected/owner-section.md"
  if [[ -f "$work/linked/used.json" ]] && jq -e 'type == "array" and all(.[]; type == "number")' "$work/linked/used.json" >/dev/null 2>&1; then
    linked=$(jq -c . "$work/linked/used.json")
  fi
fi
head=""; [[ "${HEAD_SHA:-}" =~ ^[0-9a-f]{7,64}$ ]] && head=${HEAD_SHA:0:7}

jq -s -c -L "$here/lib" --arg mode "$mode" --argjson plan "$plan" --rawfile protected "$protected" --argjson linked "$linked" --arg head "$head" \
  'include "review"; {mode: $mode, plan: $plan, calls: ., protected: $protected, linked: $linked, head: $head} | review_combine' \
  "$work/calls.jsonl" > "$work/review.json"
jq -r .body "$work/review.json" > "$work/comment.md"
verdict=$(jq -r .verdict "$work/review.json")
complete=$(jq -r .complete "$work/review.json")

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then cat "$work/comment.md" >> "$GITHUB_STEP_SUMMARY"; fi

if [[ "$mode" == owner ]]; then
  # --jq here is gh's own filter over each page; which comment to update is decided by
  # the tested function, from id, author and the first characters of the body only.
  gh api "repos/$GITHUB_REPOSITORY/issues/$pr/comments" --paginate \
    --jq '.[] | {id, login: .user.login, body: ((.body // "")[:80])}' > "$work/comments.jsonl"
  id=$(jq -s -r -L "$here/lib" 'include "review"; existing_review_comment(review_marker("owner")) // ""' "$work/comments.jsonl")
  if [[ "$id" =~ ^[0-9]+$ ]]; then
    jq -Rs '{body: .}' "$work/comment.md" > "$work/comment.json"
    gh api -X PATCH "repos/$GITHUB_REPOSITORY/issues/comments/$id" --input "$work/comment.json" >/dev/null
    echo "Updated the review comment ($id) on PR #$pr."
  else
    gh pr comment "$pr" -R "$GITHUB_REPOSITORY" --body-file "$work/comment.md" >/dev/null
    echo "Posted the review comment on PR #$pr."
  fi
  if [[ "$complete" != true ]]; then
    echo "::warning::Agent review (advisory) could not be completed for this push. The check passes regardless; the comment on the PR says what is missing."
  fi
  echo "Advisory review: verdict $verdict. The check passes whatever the verdict."
  exit 0
fi

gh pr comment "$pr" -R "$GITHUB_REPOSITORY" --body-file "$work/comment.md" >/dev/null
if [[ "$complete" != true ]]; then
  echo "::error::Agent review could not be completed"
  exit 1
fi
if [[ "$verdict" != pass ]]; then
  echo "::error::Agent review blocked this PR"
  exit 1
fi
