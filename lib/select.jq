# Pick issues the dev agent may work on tonight.
# Input:  {"issues": [gh issue list JSON: number,labels,createdAt,author,body,milestone], "prs": [gh pr list JSON]}
# Args:   --arg owner LOGIN  --argjson max N  --argjson open [open issue numbers]
#         --argjson native {"<issue number>": [open native blocker numbers]}   optional, default {}
#         --argjson milestones [{"number": N, "dueOn": "ISO date" | null}]     optional, default []
#           (the repo's OPEN milestones)
# Output: [issue numbers]
# Order:  issues in the preferred milestone first, then everything else; oldest first
#         within each group. The preferred milestone is the open milestone, among those
#         that hold at least one ready issue, with the earliest due date; milestones
#         without a due date come after dated ones, lowest number first.
include "blocked";
def names: [.labels[].name];
def has($l): names | index($l) != null;

($ARGS.named.native // {}) as $native
| ($ARGS.named.milestones // []) as $milestones
| ([.prs[].body // "" | [scan("agent-loop issue=([0-9]+)")[] | tonumber]] | add // []) as $busy
| [ .issues[]
    | select(.author.login == $owner)
    | select(has("agent:ready"))
    | select(has("agent:in-progress") | not)
    | select(has("needs:human") | not)
    | select(issue_blocked($open; $native) | not)
    | select(.number as $n | $busy | index($n) | not)
  ] as $ready
| ([$ready[] | .milestone.number? // empty] | unique) as $used
| ([$milestones[] | select(.number as $n | $used | index($n) != null)]
   | sort_by([((.dueOn // .due_on) == null), (.dueOn // .due_on // ""), .number])
   | .[0].number) as $preferred
| $ready
| sort_by(.createdAt)
# Stable: within each group the createdAt order above is kept.
| sort_by(if $preferred != null and .milestone.number? == $preferred then 0 else 1 end)
| .[:$max]
| map(.number)
