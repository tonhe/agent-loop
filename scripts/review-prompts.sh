#!/usr/bin/env bash
# Build the review prompt(s): one per Claude call.
#
# A PR at or under the split thresholds gets one prompt holding the whole diff, as
# before. A larger one (more than SPLIT_MAX_FILES files or SPLIT_MAX_LINES changed
# lines) is planned into groups by lib/split.jq and gets one prompt per group. Every
# prompt has the same header, issue context and protected-path section; a part of a
# split review also gets the list of the other parts' paths and only its own diff.
#
#   loop   header prompts/review.md, issue ISSUE through issue-context.sh (a refusal
#          fails this script, as before), protected section from review-protected.sh
#   owner  header prompts/review-owner.md, the linked issues review-linked.sh accepted
#          (or a line saying there is none), the owner-mode protected section
#
# File names come from the PR. They travel from the plan to git base64-encoded, become
# pathspecs only after "--" and with the literal magic (no globbing, no option, no
# evaluation), and are otherwise only printed.
#
# Usage: review-prompts.sh WORK_DIR                 (run in the PR checkout)
# Env:   MODE (loop|owner), ISSUE (loop mode), BASE_SHA, VERIFY_COMMAND, PLATFORMS,
#        GH_TOKEN, GITHUB_REPOSITORY, OWNER_LOGIN (issue-context.sh, loop mode),
#        SPLIT_MAX_FILES (40), SPLIT_MAX_LINES (3000), SPLIT_MAX_CALLS (8),
#        SPLIT_MAX_DIFF_BYTES (300000): anything that is not a positive whole number
#        counts as the default
# Reads  WORK_DIR/linked/issues.md, WORK_DIR/protected/{section.md,owner-section.md}
# Writes WORK_DIR/plan.json, WORK_DIR/groups/N/prompt.md, WORK_DIR/groups/N/truncated
#        (only when that group's diff was cut at SPLIT_MAX_DIFF_BYTES)
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
work=$1
mode=${MODE:-loop}
[[ "$mode" == loop || "$mode" == owner ]] || { echo "::error::MODE must be loop or owner" >&2; exit 1; }
[[ "${BASE_SHA:-}" =~ ^[0-9a-f]{7,64}$ ]] || { echo "::error::BASE_SHA is not a commit id" >&2; exit 1; }
if [[ "$mode" == loop ]]; then
  [[ "${ISSUE:-}" =~ ^[0-9]+$ ]] || { echo "::error::Need an issue number" >&2; exit 1; }
fi
num() {  # value, default -> the value if it is a positive whole number, else the default
  if [[ "$1" =~ ^[1-9][0-9]{0,8}$ ]]; then echo "$1"
  else [[ -z "$1" ]] || echo "Ignoring a split setting that is not a positive whole number; using $2." >&2; echo "$2"; fi
}
max_files=$(num "${SPLIT_MAX_FILES:-}" 40)
max_lines=$(num "${SPLIT_MAX_LINES:-}" 3000)
max_calls=$(num "${SPLIT_MAX_CALLS:-}" 8)
max_bytes=$(num "${SPLIT_MAX_DIFF_BYTES:-}" 300000)

mkdir -p "$work"
rm -rf "$work/groups" "$work/plan.json"

# Shared parts first: if the issue is refused (loop mode) nothing else is written.
if [[ "$mode" == owner ]]; then tmpl="$here/prompts/review-owner.md"; else tmpl="$here/prompts/review.md"; fi
bash "$here/scripts/render-prompt.sh" "$tmpl" > "$work/header.md"
if [[ "$mode" == loop ]]; then
  bash "$here/scripts/issue-context.sh" "$ISSUE" > "$work/issue.md"
  section="$work/protected/section.md"
else
  if [[ -s "$work/linked/issues.md" ]]; then cp "$work/linked/issues.md" "$work/issue.md"
  else echo "(The linked issues could not be read. Review the diff on its own.)" > "$work/issue.md"; fi
  section="$work/protected/owner-section.md"
fi

# --no-renames: one path per line, so a rename counts as a deletion plus an addition.
git -c core.quotePath=false diff --numstat --no-renames "$BASE_SHA"...HEAD > "$work/numstat.txt"
jq -Rs -L "$here/lib" --argjson f "$max_files" --argjson l "$max_lines" --argjson c "$max_calls" \
  'include "split"; parse_numstat | split_plan($f; $l; $c)' "$work/numstat.txt" > "$work/plan.tmp"
n=$(jq '.groups | length' "$work/plan.tmp")
split=$(jq -r .split "$work/plan.tmp")
echo "Review plan: $(jq -r '"\(.total_files) file(s), \(.total_lines) changed line(s)"' "$work/plan.tmp"); $n call(s)$([[ $(jq -r .capped "$work/plan.tmp") == true ]] && echo ", groups merged to stay within $max_calls calls")."

for ((i = 0; i < n; i++)); do
  d="$work/groups/$i"; mkdir -p "$d"
  if [[ "$split" == true ]]; then
    paths=()
    while IFS= read -r b64; do
      p=$(printf '%s' "$b64" | base64 -d; printf x)   # the x keeps a trailing newline in a name
      paths+=(":(top,literal)${p%x}")
    done < <(jq -r --argjson i "$i" '.groups[$i].paths[] | @base64' "$work/plan.tmp")
    : > "$d/diff.txt"
    for ((k = 0; k < ${#paths[@]}; k += 100)); do
      git diff "$BASE_SHA"...HEAD -- "${paths[@]:k:100}" >> "$d/diff.txt"
    done
  else
    git diff "$BASE_SHA"...HEAD > "$d/diff.txt"
  fi
  cut=false
  if (( $(wc -c < "$d/diff.txt") > max_bytes )); then
    # Cut at the limit, then drop the last, probably partial, line.
    head -c "$max_bytes" "$d/diff.txt" | sed '$d' > "$d/diff.cut"
    mv "$d/diff.cut" "$d/diff.txt"
    cut=true; : > "$d/truncated"
  fi
  {
    cat "$work/header.md"; echo
    echo "## Issue"; cat "$work/issue.md"; echo
    if [[ -s "$section" ]]; then cat "$section"; echo; fi
    if [[ "$split" == true ]]; then
      jq -r -L "$here/lib" --argjson i "$i" 'include "review"; scope_section($i; 400)' "$work/plan.tmp"; echo
    fi
    echo "## Diff"; echo '```diff'; cat "$d/diff.txt"; echo '```'
    if [[ "$cut" == true ]]; then
      echo
      echo "(diff truncated: the diff above was cut at $max_bytes bytes, so part of it is not shown. Say in your summary that you did not see the whole diff, and use Read and \`git diff\` for the files you need.)"
    fi
  } > "$d/prompt.md"
  rm -f "$d/diff.txt"
  echo "Part $((i + 1)) of $n: $(jq -r --argjson i "$i" '.groups[$i] | "\(.files) file(s), \(.lines) changed line(s)"' "$work/plan.tmp")$([[ "$cut" == true ]] && echo ", diff truncated")."
done
# Last, so that a plan is only ever there together with all of its prompts.
mv "$work/plan.tmp" "$work/plan.json"
