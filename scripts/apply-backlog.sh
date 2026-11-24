#!/usr/bin/env bash
# Validate the backlog plan and apply what passes. Prints a Markdown digest to stdout.
# Usage: apply-backlog.sh WORK_DIR   (expects candidates.json, current-labels.json, external.json, claude/result.json)
# Env:   GH_TOKEN (the PAT, so changes appear as the owner), GITHUB_REPOSITORY,
#        ALLOW_MEDIUM_RISK (true|false), DRY_RUN (true|false), MAX_NEW_ISSUES
# Exit:  0 ok, 5 there were candidates but the plan applied nothing (digest is still printed).
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
w=$1
repo=$GITHUB_REPOSITORY
dry=${DRY_RUN:-false}
max_new=${MAX_NEW_ISSUES:-10}

run() { if [[ $dry == true ]]; then echo "DRY: $*" >&2; else "$@"; fi; }

allowed=$(jq -c '[.[].number]' "$w/candidates.json")
jq --argjson allowed "$allowed" \
   --argjson current "$(cat "$w/current-labels.json")" \
   --argjson allow_medium "${ALLOW_MEDIUM_RISK:-false}" \
   -f "$here/lib/validate-plan.jq" "$w/claude/result.json" > "$w/validated.json"

new_issues=0
digest=()
while read -r a; do
  n=$(jq -r '.issue' <<<"$a")
  add=$(jq -r '.add_labels | join(",")' <<<"$a")
  rm_=$(jq -r '.remove_labels | join(",")' <<<"$a")
  args=()
  [[ -n $add ]] && args+=(--add-label "$add")
  [[ -n $rm_ ]] && args+=(--remove-label "$rm_")
  (( ${#args[@]} )) && run gh issue edit "$n" -R "$repo" "${args[@]}"

  # One assessment comment per issue, updated in place. The issue body is never touched.
  body=""
  if [[ $(jq -r '.assessment // empty' <<<"$a") != "" ]]; then
    body+=$'<!-- agent-assessment -->\n## Agent Assessment\n\n'"$(jq -r '.assessment' <<<"$a")"$'\n'
  fi
  if [[ $(jq -r '.question // empty' <<<"$a") != "" ]]; then
    body+=$'\n### Questions\n\n'"$(jq -r '.question' <<<"$a")"$'\n'
  fi
  notes=$(jq -r '.notes | map("- " + .) | join("\n")' <<<"$a")
  [[ -n $notes ]] && body+=$'\n### Guardrail notes\n\n'"$notes"$'\n'

  # Splits: new issues filed as the owner, linked to the parent, left unlabeled for the next run.
  children=()
  while read -r s; do
    [[ -z $s ]] && continue
    if (( new_issues >= max_new )); then body+=$'\n(Split limit reached for this run.)\n'; break; fi
    t=$(jq -r '.title' <<<"$s")
    # The model wrote this body; a Base: line in it must not steer a later dev run.
    b="$(jq -r -L "$here/lib" 'include "base"; .body | defang_base' <<<"$s")"$'\n\nSplit from #'"$n"
    if [[ $dry == true ]]; then url="DRY-new-issue"; echo "DRY: create issue '$t'" >&2
    else url=$(gh issue create -R "$repo" --title "$t" --body "$b"); fi
    children+=("$url"); new_issues=$((new_issues + 1))
  done < <(jq -c '.split_into[]?' <<<"$a")
  if (( ${#children[@]} )); then
    body+=$'\n### Split into\n\n'"$(printf -- '- %s\n' "${children[@]}")"
    run gh issue edit "$n" -R "$repo" --remove-label agent:ready 2>/dev/null || true
  fi

  if [[ -n $body ]]; then
    if [[ $(jq -r '.assessment // empty' <<<"$a") == "" ]]; then body=$'<!-- agent-assessment -->\n'"$body"; fi
    existing=$(gh api "repos/$repo/issues/$n/comments" --paginate \
                 --jq "[.[] | select(.user.login == \"$OWNER_LOGIN\" and (.body | contains(\"<!-- agent-assessment -->\")))] | last | .id // empty")
    if [[ -n $existing ]]; then
      run gh api -X PATCH "repos/$repo/issues/comments/$existing" -f body="$body" >/dev/null
    else
      run gh issue comment "$n" -R "$repo" --body "$body" >/dev/null
    fi
  fi

  label_note=""
  [[ -n $add ]] && label_note+=" +$add"
  [[ -n $rm_ ]] && label_note+=" -$rm_"
  [[ ${#children[@]} -gt 0 ]] && label_note+=" split into ${#children[@]}"
  digest+=("- #$n${label_note:- assessed}")
done < <(jq -c '.apply[]' "$w/validated.json")

rejected=$(jq -r '.rejected[] | "- #\(.issue): \(.reason)"' "$w/validated.json")
external=$(jq -r 'if length == 0 then "none" else map("#\(.number) by \(.author)") | join(", ") end' "$w/external.json")

# Every candidate should get an action. Name the ones the plan skipped, and treat a plan
# that applies nothing at all as a failed run rather than a quiet success.
n_cand=$(jq 'length' "$w/candidates.json")
n_apply=$(jq '.apply | length' "$w/validated.json")
unanswered=$(jq -r --slurpfile plan "$w/claude/result.json" \
  '[.[].number] - [($plan[0].actions // [])[].issue] | map("#\(.)") | join(", ")' "$w/candidates.json")
empty_plan=false
if (( n_cand > 0 && n_apply == 0 )); then empty_plan=true; fi

{
  echo "**Backlog: ${GITHUB_REPOSITORY#*/}**"
  jq -r '.summary // ""' "$w/claude/result.json"
  echo
  if [[ $empty_plan == true ]]; then
    echo "**FAILED: the plan had no usable actions for $n_cand candidate issue(s). Nothing was applied.**"
  elif (( ${#digest[@]} )); then printf '%s\n' "${digest[@]}"
  else echo "- nothing needed assessment"; fi
  [[ -n $unanswered && $empty_plan == false ]] && echo "No action returned for: $unanswered"
  [[ -n $rejected ]] && { echo "Rejected by guardrails:"; echo "$rejected"; }
  [[ -s "$w/blocked.json" ]] && echo "Waiting on blockers: $(jq -r 'length' "$w/blocked.json") issue(s)"
  echo "External issues waiting for you to adopt: $external"
}

if [[ $empty_plan == true ]]; then
  echo "::error::Backlog plan had no usable actions for $n_cand candidate issue(s)" >&2
  exit 5
fi
