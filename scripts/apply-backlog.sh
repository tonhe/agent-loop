#!/usr/bin/env bash
# Validate the backlog plan and apply what passes. Prints a Markdown digest to stdout.
# Usage: apply-backlog.sh WORK_DIR   (expects candidates.json, current-labels.json, external.json, claude/result.json;
#                                     planning.json from plan-due.sh is optional)
# When planning.json says a milestone plan is due and the plan carries a proposal, the
# "Plan vX.Y" issue is filed as the owner: body rendered by lib/planning.jq (plan_body),
# label needs:human and nothing else, no milestone. Nothing here ever sets a milestone.
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
    # The model wrote this title and body. The title must not read as a Release or Plan
    # issue, a Base: line must not steer a later dev run, and no agent marker may be forged.
    t=$(jq -r -L "$here/lib" 'include "meta"; .title | safe_title' <<<"$s")
    b="$(jq -r -L "$here/lib" 'include "base"; include "meta"; .body | defang_base | defang_markers' <<<"$s")"$'\n\nSplit from #'"$n"
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

# Milestone planning: propose only. The title comes from plan-due.sh, the body from
# plan_body (model text reduced to single lines, Base: lines defanged, only issues that
# were offered), the label is fixed.
plan_line=""
if [[ -s "$w/planning.json" && $(jq -r '.due' "$w/planning.json") == true ]]; then
  ptitle=$(jq -r '.title' "$w/planning.json")
  if ! [[ "$ptitle" =~ ^Plan\ v[0-9]+\.[0-9]+$ ]]; then
    plan_line="- planning: unexpected plan title; nothing filed"
  elif ! jq -e '(.planning // null) | type == "object"' "$w/claude/result.json" >/dev/null 2>&1; then
    plan_line="- planning: \`$ptitle\` was due but the plan carried no proposal; it will be asked for again next run"
  # The proposal is model output and may not have the shape plan_body expects (a list
  # that is a string, say). That costs the Plan issue for tonight, not the triage digest.
  elif ! jq -r -L "$here/lib" --slurpfile p "$w/planning.json" 'include "planning"; .planning | plan_body($p[0])' \
         "$w/claude/result.json" > "$w/plan-body.md" 2>"$w/plan-body.err" || [[ ! -s "$w/plan-body.md" ]]; then
    rm -f "$w/plan-body.md"
    # jq's message can quote model text, so it stays in the file and out of the annotation.
    echo "::warning::The planning proposal could not be rendered (jq said so in plan-body.err); no Plan issue filed." >&2
    plan_line="- planning: proposal could not be rendered; nothing filed. \`$ptitle\` will be asked for again next run"
  else
    if [[ $dry == true ]]; then
      echo "DRY: create issue '$ptitle' (needs:human, assigned to $OWNER_LOGIN)" >&2
      plan_line="- planning: would open \`$ptitle\` (dry run)"
    elif url=$(gh issue create -R "$repo" --title "$ptitle" --body-file "$w/plan-body.md" --label needs:human --assignee "$OWNER_LOGIN"); then
      plan_line="- planning: opened #${url##*/} \`$ptitle\` for you to answer"
    else
      plan_line="- planning: could not open \`$ptitle\`; see the log"
    fi
  fi
fi

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
  [[ -n $plan_line ]] && echo "$plan_line"
  [[ -n $unanswered && $empty_plan == false ]] && echo "No action returned for: $unanswered"
  [[ -n $rejected ]] && { echo "Rejected by guardrails:"; echo "$rejected"; }
  [[ -s "$w/blocked.json" ]] && echo "Waiting on blockers: $(jq -r 'length' "$w/blocked.json") issue(s)"
  echo "External issues waiting for you to adopt: $external"
}

if [[ $empty_plan == true ]]; then
  echo "::error::Backlog plan had no usable actions for $n_cand candidate issue(s)" >&2
  exit 5
fi
