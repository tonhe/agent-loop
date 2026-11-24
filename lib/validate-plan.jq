# Turn the backlog manager's proposed plan into a safe, enforced action list.
# Input:  plan (schemas/backlog-plan.json shape)
# Args:   --argjson allowed [issue numbers sent to the agent]
#         --argjson current {"<n>": [current label names]}
#         --argjson allow_medium true|false
# Output: {"apply": [...], "rejected": [{issue, reason}]}
#
# Rules enforced here (not in the prompt):
#  - only issues that were handed to the agent (all owner-authored)
#  - only managed labels; agent:urgent / agent:in-progress are never touchable
#  - existing risk:/type: labels are kept; a disagreement is reported instead
#  - agent:ready only if the resulting risk is low (or medium when allowed)
#  - agent:ready and needs:human are mutually exclusive
#  - at most 5 splits per issue
def managed: ["risk:low","risk:medium","risk:high",
              "type:bug","type:feature","type:docs","type:test","type:refactor","type:chore",
              "agent:ready","needs:human"];
def prefix($p): map(select(startswith($p)));

reduce (.actions // [])[] as $a ({apply: [], rejected: []};
  if ($allowed | index($a.issue)) == null then
    .rejected += [{issue: $a.issue, reason: "issue not in allowed set"}]
  else
    ($current[($a.issue | tostring)] // []) as $cur
    | ([($a.add_labels // [])[] | select(. as $l | managed | index($l) != null)]) as $add0
    | ([($a.add_labels // [])[] | select(. as $l | managed | index($l) == null)]) as $bad
    # keep human/previous risk and type labels
    | (if ($cur | prefix("risk:") | length) > 0 then $add0 | map(select(startswith("risk:") | not)) else $add0 end) as $add1
    | (if ($cur | prefix("type:") | length) > 0 then $add1 | map(select(startswith("type:") | not)) else $add1 end) as $add2
    # one of each at most
    | ([$add2[] | select(startswith("risk:"))][:1] + [$add2[] | select(startswith("type:"))][:1]
       + [$add2[] | select(startswith("agent:") or startswith("needs:"))] | unique) as $add3
    | ([($a.remove_labels // [])[] | select(. == "agent:ready" or . == "needs:human")]) as $remove
    | ((($cur + $add3) - $remove) | unique) as $final
    | ([$final[] | select(startswith("risk:"))][0] // "none") as $risk
    | ($risk == "risk:low" or ($allow_medium and $risk == "risk:medium")) as $risk_ok
    | (if ($add3 | index("agent:ready")) != null and ($risk_ok | not)
         then {labels: ($add3 - ["agent:ready"] + ["needs:human"] | unique),
               note: "agent:ready refused: risk is \($risk)"}
         else {labels: $add3, note: null} end) as $gate
    | (if ($gate.labels | index("agent:ready")) != null
         then $gate.labels - ["needs:human"] else $gate.labels end) as $add_final
    | ((if ($add_final | index("needs:human")) != null then $remove + ["agent:ready"] else $remove end)
       | if ($add_final | index("agent:ready")) != null then . + ["needs:human"] else . end
       | unique | map(select(. as $l | $cur | index($l) != null))) as $remove_final
    | .apply += [{
        issue: $a.issue,
        add_labels: ($add_final - $cur),
        remove_labels: $remove_final,
        assessment: ($a.assessment // null),
        question: ($a.question // null),
        split_into: (($a.split_into // [])[:5]),
        notes: ([$gate.note, (if ($bad | length) > 0 then "ignored unmanaged labels: \($bad | join(", "))" else empty end)]
                | map(select(. != null)))
      }]
  end)
