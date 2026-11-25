#!/usr/bin/env bash
# Validate the backlog plan and apply what passes. Prints a Markdown digest to stdout.
# Usage: apply-backlog.sh WORK_DIR   (expects candidates.json, current-labels.json, external.json, claude/result.json;
#                                     planning.json from plan-due.sh is optional)
# When planning.json says a milestone plan is due and the plan carries a proposal, the
# "Plan vX.Y" issue is filed as the owner: body rendered by lib/planning.jq (plan_body),
# label needs:human and nothing else, no milestone. Nothing here ever sets a milestone.
# Env:   GH_TOKEN (the PAT, so changes appear as the owner), GITHUB_REPOSITORY,
#        ALLOW_MEDIUM_RISK (true|false), DRY_RUN (true|false), MAX_NEW_ISSUES
# Exit:  0 ok, 5 there were candidates but the plan applied nothing, 6 a gh call failed for
#        at least one issue (the rest was applied). The digest is printed in every case.
# A gh call that fails for one issue (labels, a split, the comment) costs that step of that
# issue only: it is named on the issue's digest line, a ::warning:: goes to the log, the
# loop goes on, and the script exits 6 after the digest.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
w=$1
repo=$GITHUB_REPOSITORY
dry=${DRY_RUN:-false}
max_new=${MAX_NEW_ISSUES:-10}

# This script's stdout is the digest, and nothing else may be written to it. gh prints the
# issue URL on `issue edit` and `issue comment`; those would land at the top of the digest,
# where Discord turns each one into a preview card. So run() sends a command's stdout to
# stderr (the job log). A call whose output is needed (issue create) does not use run().
run() { if [[ $dry == true ]]; then echo "DRY: $*" >&2; else "$@" >&2; fi; }

allowed=$(jq -c '[.[].number]' "$w/candidates.json")
# Issues with an "Owner decision" comment (a fact from candidates.jq): validate-plan.jq
# changes no label on them and files no split, so only the comment below is posted.
decided=$(jq -c '[.[] | select(.owner_decision == true) | .number]' "$w/candidates.json")
# Sub-issues of an agent:paired epic (the paired_parent fact from candidates.jq):
# validate-plan.jq labels them agent:paired and routes them nowhere else.
paired_parents=$(jq -c '[.[] | select((.paired_parent | type) == "number") | {key: (.number | tostring), value: .paired_parent}] | from_entries' "$w/candidates.json")
jq --argjson allowed "$allowed" \
   --argjson decided "$decided" \
   --argjson paired_parents "$paired_parents" \
   --argjson current "$(cat "$w/current-labels.json")" \
   --argjson allow_medium "${ALLOW_MEDIUM_RISK:-false}" \
   -f "$here/lib/validate-plan.jq" "$w/claude/result.json" > "$w/validated.json"

new_issues=0
digest=()
failed_issues=0
# step_failed STEP TEXT: a gh call for issue $n failed. TEXT goes on the issue's digest
# line; the annotation names the issue and the step only, never text the model wrote.
step_failed() {
  failures+=("$2")
  echo "::warning::Backlog apply: $1 failed for #$n (gh said why just above)." >&2
}
while read -r a; do
  n=$(jq -r '.issue' <<<"$a")
  failures=()
  # agent:paired (validate-plan.jq adds it to a sub-issue of a paired epic) is applied in
  # a call of its own, below; $add holds the other labels.
  add=$(jq -r '.add_labels - ["agent:paired"] | join(",")' <<<"$a")
  rm_=$(jq -r '.remove_labels | join(",")' <<<"$a")
  args=()
  [[ -n $add ]] && args+=(--add-label "$add")
  [[ -n $rm_ ]] && args+=(--remove-label "$rm_")
  # The digest reports $add and $rm_, so a failed edit empties them: the line must not
  # claim a change that was not made. What was asked for is named as the failure instead.
  if (( ${#args[@]} )) && ! run gh issue edit "$n" -R "$repo" "${args[@]}"; then
    step_failed labels "label edit (wanted${add:+ +$add}${rm_:+ -$rm_})"
    add=""; rm_=""
  fi
  # A repository that never ran bootstrap-labels.sh since agent:paired exists has no such
  # label, and gh then refuses the edit. This addition has its own wording and does not
  # count as a failed run: the issue keeps its other labels, is left without a
  # routing label (validate-plan.jq dropped agent:ready and needs:human, and the edit
  # above removed the ones it had) and the digest says so.
  pair_failed=false
  if [[ $(jq -r '.add_labels | index("agent:paired") != null' <<<"$a") == true ]]; then
    if run gh issue edit "$n" -R "$repo" --add-label agent:paired; then
      add="agent:paired${add:+,$add}"
    else
      pair_failed=true
      echo "::warning::Could not add agent:paired to #$n. If the label does not exist, run scripts/bootstrap-labels.sh." >&2
    fi
  fi

  # One assessment comment per issue, updated in place. The issue body is never touched.
  body=""
  if [[ $(jq -r '.assessment // empty' <<<"$a") != "" ]]; then
    body+=$'<!-- agent-assessment -->\n## Agent Assessment\n\n'"$(jq -r '.assessment' <<<"$a")"$'\n'
  fi
  if [[ $(jq -r '.question // empty' <<<"$a") != "" ]]; then
    body+=$'\n### Questions\n\n'"$(jq -r '.question' <<<"$a")"$'\n'
  fi
  notes=$(jq -r '.notes | map("- " + .) | join("\n")' <<<"$a")
  [[ $pair_failed == true ]] && notes+=$'\n- agent:paired could not be added to this issue (does the label exist? run scripts/bootstrap-labels.sh); it has no routing label for now'
  [[ -n $notes ]] && body+=$'\n### Guardrail notes\n\n'"$notes"$'\n'

  # Splits: new issues filed as the owner, linked to the parent, left unlabeled for the next run.
  children=()
  split_failed=0
  while read -r s; do
    [[ -z $s ]] && continue
    if (( new_issues >= max_new )); then body+=$'\n(Split limit reached for this run.)\n'; break; fi
    # The model wrote this title and body. The title must not read as a Release or Plan
    # issue, a Base: line must not steer a later dev run, and no agent marker may be forged.
    t=$(jq -r -L "$here/lib" 'include "meta"; .title | safe_title' <<<"$s")
    b="$(jq -r -L "$here/lib" 'include "base"; include "meta"; .body | defang_base | defang_markers' <<<"$s")"$'\n\nSplit from #'"$n"
    if [[ $dry == true ]]; then url="DRY-new-issue"; echo "DRY: create issue '$t'" >&2
    elif ! url=$(gh issue create -R "$repo" --title "$t" --body "$b"); then
      split_failed=$((split_failed + 1)); continue
    fi
    children+=("$url"); new_issues=$((new_issues + 1))
  done < <(jq -c '.split_into[]?' <<<"$a")
  if (( split_failed )); then step_failed split "$split_failed split issue(s) not filed"; fi
  # A child that was filed exists whatever happens next. If the comment that links it
  # cannot be posted, the digest names it by number (a URL would become a preview card).
  unlinked=""
  if (( ${#children[@]} )); then
    unlinked=$(printf '#%s, ' "${children[@]##*/}")
    unlinked=" (split issue(s) ${unlinked%, } filed, not linked from #$n)"
    body+=$'\n### Split into\n\n'"$(printf -- '- %s\n' "${children[@]}")"
    run gh issue edit "$n" -R "$repo" --remove-label agent:ready 2>/dev/null || true
  fi

  if [[ -n $body ]]; then
    if [[ $(jq -r '.assessment // empty' <<<"$a") == "" ]]; then body=$'<!-- agent-assessment -->\n'"$body"; fi
    # Without the answer there is no telling whether to update or to post, and posting
    # blind could leave two assessment comments, so a failed lookup posts nothing.
    if ! existing=$(gh api "repos/$repo/issues/$n/comments" --paginate \
                 --jq "[.[] | select(.user.login == \"$OWNER_LOGIN\" and (.body | contains(\"<!-- agent-assessment -->\")))] | last | .id // empty"); then
      step_failed "comment lookup" "comment not posted (could not look for an earlier one)$unlinked"
    elif [[ -n $existing ]]; then
      run gh api -X PATCH "repos/$repo/issues/comments/$existing" -f body="$body" >/dev/null \
        || step_failed comment "comment not updated$unlinked"
    else
      run gh issue comment "$n" -R "$repo" --body "$body" >/dev/null \
        || step_failed comment "comment not posted$unlinked"
    fi
  fi

  label_note=""
  [[ -n $add ]] && label_note+=" +$add"
  [[ -n $rm_ ]] && label_note+=" -$rm_"
  [[ ${#children[@]} -gt 0 ]] && label_note+=" split into ${#children[@]}"
  [[ $pair_failed == true ]] && label_note+=" (agent:paired could not be added; run scripts/bootstrap-labels.sh)"
  if (( ${#failures[@]} )); then
    failed_issues=$((failed_issues + 1))
    digest+=("- #$n$label_note FAILED: $(printf '%s; ' "${failures[@]}")see the log")
  else
    digest+=("- #$n${label_note:- assessed}")
  fi
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
  elif (( ${#digest[@]} )); then
    if (( failed_issues )); then
      echo "**FAILED: $failed_issues of $n_apply issue(s) had a step that failed (marked FAILED below). Everything else was applied.**"
    fi
    printf '%s\n' "${digest[@]}"
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
if (( failed_issues )); then
  echo "::error::Backlog apply: $failed_issues of $n_apply issue(s) had a failed step; the digest names each one" >&2
  exit 6
fi
