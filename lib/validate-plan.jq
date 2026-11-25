# Turn the backlog manager's proposed plan into a safe, enforced action list.
# Input:  plan (schemas/backlog-plan.json shape)
# Args:   --argjson allowed [issue numbers sent to the agent]
#         --argjson current {"<n>": [current label names]}
#         --argjson allow_medium true|false
#         --argjson decided [issue numbers with an "Owner decision" comment]   optional, default []
#         --argjson paired_parents {"<n>": number of the agent:paired epic it is a sub-issue of}
#                                                                              optional, default {}
# Output: {"apply": [...], "rejected": [{issue, reason}]}
#
# Rules enforced here (not in the prompt):
#  - only issues that were handed to the agent (all owner-authored)
#  - only managed labels; agent:urgent / agent:in-progress are never touchable
#  - existing risk:/type: labels are kept; a disagreement is reported instead
#  - agent:ready only if the resulting risk is low (or medium when allowed)
#  - agent:ready and needs:human are mutually exclusive
#  - at most 5 splits per issue; a split child is a title and a body, nothing else
#  - agent:paired (owned by the owner's interactive agent) freezes routing: agent:ready
#    and needs:human are neither added nor removed and the issue is not split; the label
#    itself is untouchable like agent:urgent. Risk/type labels and the assessment stay allowed.
#  - a sub-issue of an agent:paired epic ($paired_parents, a fact from candidates.jq) is
#    labeled agent:paired here, whatever the plan proposed and whatever it carried:
#    agent:ready and needs:human are not added, and are removed when the issue has them,
#    so it ends with agent:paired and neither routing label. No split. This is the only
#    place agent:paired is ever added; the plan itself still cannot add or remove it. A
#    sub-issue that already carries agent:paired is under the freeze above instead: its
#    routing labels are left as they are.
#  - an issue with an "Owner decision" comment ($decided, a fact from candidates.jq) keeps
#    its labels exactly as they are: nothing is added or removed (routing, risk and type
#    alike), the risk gate adds no needs:human, and the issue is not split. The assessment
#    and the question are kept: triage may only comment. This rule comes first: a decided
#    sub-issue of a paired epic does not get agent:paired either.
#  - nothing here can set a milestone: the output is built field by field, so a
#    "milestone" (or any other extra field) in an action or a split child is dropped
def managed: ["risk:low","risk:medium","risk:high",
              "type:bug","type:feature","type:docs","type:test","type:refactor","type:chore",
              "agent:ready","needs:human"];
def prefix($p): map(select(startswith($p)));

($ARGS.named.decided // []) as $decided
| ($ARGS.named.paired_parents // {}) as $paired_parents
| reduce (.actions // [])[] as $a ({apply: [], rejected: []};
  if ($allowed | index($a.issue)) == null then
    .rejected += [{issue: $a.issue, reason: "issue not in allowed set"}]
  elif ($decided | index($a.issue)) != null then
    # Owner decision: the owner's routing stands. None of the label rules below run.
    .apply += [{
      issue: $a.issue,
      add_labels: [],
      remove_labels: [],
      assessment: ($a.assessment // null),
      question: ($a.question // null),
      split_into: [],
      notes: (if (($a.add_labels // []) + ($a.remove_labels // []) + ($a.split_into // []) | length) > 0
              then ["labels left alone and no split: the issue has an Owner decision comment, so triage only comments"]
              else [] end)
    }]
  else
    ($current[($a.issue | tostring)] // []) as $cur
    | ([($a.add_labels // [])[] | select(. as $l | managed | index($l) != null)]) as $add0
    | ([($a.add_labels // [])[] | select(. as $l | managed | index($l) == null)]) as $bad
    # keep human/previous risk and type labels
    | (if ($cur | prefix("risk:") | length) > 0 then $add0 | map(select(startswith("risk:") | not)) else $add0 end) as $add1
    | (if ($cur | prefix("type:") | length) > 0 then $add1 | map(select(startswith("type:") | not)) else $add1 end) as $add2
    # agent:paired, on the issue itself or on the epic it is a sub-issue of: routing is frozen
    | ([$paired_parents[($a.issue | tostring)] | numbers][0] // null) as $epic
    | (($cur | index("agent:paired")) != null) as $has_paired
    | ($has_paired or $epic != null) as $paired
    # $adopt: a sub-issue of a paired epic that is not agent:paired yet
    | ($epic != null and ($has_paired | not)) as $adopt
    # the plan naming agent:paired on such an issue asks for what happens anyway
    | (if $adopt then $bad - ["agent:paired"] else $bad end) as $bad
    | (if $paired then $add2 | map(select(. != "agent:ready" and . != "needs:human")) else $add2 end) as $add2
    # one of each at most
    | ([$add2[] | select(startswith("risk:"))][:1] + [$add2[] | select(startswith("type:"))][:1]
       + [$add2[] | select(startswith("agent:") or startswith("needs:"))] | unique) as $add3
    # $adopt: both routing labels go (those the issue has; see $remove_final), asked or not
    | (if $adopt then ["agent:ready", "needs:human"]
       else [($a.remove_labels // [])[] | select(. == "agent:ready" or . == "needs:human") | select($paired | not)] end) as $remove
    | ((($cur + $add3) - $remove) | unique) as $final
    | ([$final[] | select(startswith("risk:"))][0] // "none") as $risk
    | ($risk == "risk:low" or ($allow_medium and $risk == "risk:medium")) as $risk_ok
    | (if ($add3 | index("agent:ready")) != null and ($risk_ok | not)
         then {labels: ($add3 - ["agent:ready"] + ["needs:human"] | unique),
               note: "agent:ready refused: risk is \($risk)"}
         else {labels: $add3, note: null} end) as $gate
    | (if ($gate.labels | index("agent:ready")) != null
         then $gate.labels - ["needs:human"] else $gate.labels end) as $add_final
    # a sub-issue of a paired epic becomes agent:paired itself
    | (if $adopt then $add_final + ["agent:paired"] | unique else $add_final end) as $add_final
    | ((if ($add_final | index("needs:human")) != null then $remove + ["agent:ready"] else $remove end)
       | if ($add_final | index("agent:ready")) != null then . + ["needs:human"] else . end
       | unique | map(select(. as $l | $cur | index($l) != null))) as $remove_final
    | .apply += [{
        issue: $a.issue,
        add_labels: ($add_final - $cur),
        remove_labels: $remove_final,
        assessment: ($a.assessment // null),
        question: ($a.question // null),
        split_into: (if $paired then [] else [($a.split_into // [])[:5][] | {title, body}] end),
        notes: ([$gate.note,
                 (if ($bad | length) > 0 then "ignored unmanaged labels: \($bad | join(", "))" else empty end),
                 (if $adopt
                  then "agent:paired added, agent:ready and needs:human dropped, and no split: sub-issue of #\($epic), which is agent:paired (owned by the interactive agent)"
                  elif $paired and ((($a.add_labels // []) + ($a.remove_labels // []) | map(select(. == "agent:ready" or . == "needs:human")) | length) > 0
                                  or (($a.split_into // []) | length) > 0)
                  then "routing left alone: agent:paired (owned by the interactive agent)" else empty end)]
                | map(select(. != null)))
      }]
  end)
