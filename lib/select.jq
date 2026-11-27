# Pick issues the dev agent may work on tonight.
# Input:  {"issues": [gh issue list JSON: number,labels,createdAt,author,body,milestone],
#          "prs": [gh pr list JSON: number,body,headRefName,isCrossRepository,author]}
# Args:   --arg owner LOGIN  --argjson max N  --argjson open [open issue numbers]
#         --argjson native {"<issue number>": [open native blocker numbers]}   optional, default {}
#         --argjson milestones [{"number": N, "dueOn": "ISO date" | null, "description": text | null}]
#           (the repo's OPEN milestones)                                        optional, default []
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
#           4. type:enhancement   5. type:feature   6. none of these labels
#         An issue in several groups counts in the earliest one. Any other order value is
#         an error.
# Release mode (#61, lib/release-mode.jq): a type:feature issue is picked only when it is
# in an open milestone whose description approves it for release. In maintenance mode
# (no such milestone, or no milestones given) no feature is picked, agent:ready or not.
# Never picked here: agent:paired issues (owned by the owner's interactive agent) and the
# Release / Plan issues the loop files itself (lib/meta.jq).
# Busy:   an issue with an open PR is skipped. Issue N is busy only when an open PR that
#         is not from a fork and was opened by the owner has the head branch issue-N
#         (lib/pr.jq). The PR body is not read: a missing or wrong marker must not free
#         the issue (publish-pr.sh would force-push issue-N over the PR under review), and
#         a marker in someone else's PR, or their fork's branch name, must not block one.
#         Each PR needs the fields number, headRefName, isCrossRepository, author; a list
#         without them is an error.
include "blocked";
include "pr";
include "meta";
include "milestone";
include "release-mode";
def names: [.labels[].name];
def has($l): names | index($l) != null;

# type_group: issue -> 0..4, the label group used by order "type".
def type_group:
  names as $l
  | def any_of($want): any($want[]; . as $w | $l | index($w) != null);
    if any_of(["type:bug"]) then 0
    elif any_of(["tech-debt"]) then 1
    elif any_of(["type:refactor", "type:chore", "type:test", "type:docs"]) then 2
    elif any_of(["type:enhancement"]) then 3
    elif any_of(["type:feature"]) then 4
    else 5 end;

($ARGS.named.native // {}) as $native
| ($ARGS.named.order // "oldest") as $order
| (if $order == "oldest" or $order == "type" then . else error("unknown order: use oldest or type") end)
| ($ARGS.named.milestones // []) as $milestones
| ($milestones | approved_milestones) as $approved
| (.prs
   | map(if type == "object" and (["headRefName", "isCrossRepository", "author"] - keys == []) then .
         else error("select: every PR needs headRefName, isCrossRepository and author; without them no issue would look busy") end)
   | map(select(.isCrossRepository == false and .author.login? == $owner) | branch_issue | values)) as $busy
| [ .issues[]
    | select(.author.login == $owner)
    | select(has("agent:ready"))
    | select(has("agent:in-progress") | not)
    | select(has("needs:human") | not)
    | select(has("agent:paired") | not)
    | select(is_meta_issue | not)
    | select(ready_allowed($approved))
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
