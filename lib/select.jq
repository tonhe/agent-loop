# Pick issues the dev agent may work on tonight.
# Input:  {"issues": [gh issue list JSON: number,labels,createdAt,author,body,milestone], "prs": [gh pr list JSON]}
# Args:   --arg owner LOGIN  --argjson max N  --argjson open [open issue numbers]
#         --argjson native {"<issue number>": [open native blocker numbers]}   optional, default {}
#         --argjson milestones [{"number": N, "dueOn": "ISO date" | null}]     optional, default []
#           (the repo's OPEN milestones)
#         --arg order oldest|type                                               optional, default oldest
# Output: [issue numbers]
# Order:  three groups, oldest first within each:
#           1. issues in the preferred milestone
#           2. issues in any other open milestone
#           3. issues with no milestone (or one that is not in $milestones, i.e. closed)
#         The preferred milestone is the open milestone, among those that hold at least
#         one ready issue, with the earliest due date; milestones without a due date come
#         after dated ones, lowest number first (lib/milestone.jq).
#         With order "type" the milestone groups still come first; inside each, issues go
#         by label group, then oldest first:
#           1. type:bug   2. tech-debt   3. type:refactor, type:chore, type:test, type:docs
#           4. type:feature   5. none of these labels
#         An issue in several groups counts in the earliest one. Any other order value is
#         an error.
# Never picked here: agent:paired issues (owned by the owner's interactive agent) and the
# Release / Plan issues the loop files itself (lib/meta.jq).
include "blocked";
include "meta";
include "milestone";
def names: [.labels[].name];
def has($l): names | index($l) != null;

# type_group: issue -> 0..4, the label group used by order "type".
def type_group:
  names as $l
  | def any_of($want): any($want[]; . as $w | $l | index($w) != null);
    if any_of(["type:bug"]) then 0
    elif any_of(["tech-debt"]) then 1
    elif any_of(["type:refactor", "type:chore", "type:test", "type:docs"]) then 2
    elif any_of(["type:feature"]) then 3
    else 4 end;

($ARGS.named.native // {}) as $native
| ($ARGS.named.order // "oldest") as $order
| (if $order == "oldest" or $order == "type" then . else error("unknown order: use oldest or type") end)
| ($ARGS.named.milestones // []) as $milestones
| ([.prs[].body // "" | [scan("agent-loop issue=([0-9]+)")[] | tonumber]] | add // []) as $busy
| [ .issues[]
    | select(.author.login == $owner)
    | select(has("agent:ready"))
    | select(has("agent:in-progress") | not)
    | select(has("needs:human") | not)
    | select(has("agent:paired") | not)
    | select(is_meta_issue | not)
    | select(issue_blocked($open; $native) | not)
    | select(.number as $n | $busy | index($n) | not)
  ] as $ready
| ([$ready[] | .milestone.number? // empty] | unique) as $used
| ($milestones | preferred_milestone($used)) as $preferred
| [$milestones[].number] as $open_ms
| $ready
| sort_by([((.milestone.number? // null) as $m
            | if $m == null then 2
              elif $m == $preferred then 0
              elif ($open_ms | index($m)) != null then 1
              else 2 end),
           (if $order == "type" then type_group else 0 end),
           .createdAt])
| .[:$max]
| map(.number)
