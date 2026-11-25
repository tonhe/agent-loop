# Decide what the follow-up job should do with one agent PR.
# Input:  {"pr": gh pr view JSON (number,headRefName,body,createdAt,isCrossRepository,
#                state,comments,reviews), "now": epoch seconds,
#          "issue_labels": [names of the issue's labels]}
# Args:   --arg owner LOGIN  --argjson grace_minutes N     (run with -L lib)
# Output: {"agent_pr": bool, "issue": N|null, "fix_round": bool, "auto_merge": bool, "reason": "..."}
#
# The issue is the N of the head branch issue-N (lib/pr.jq), never a number from the PR
# body: the body starts with model text. The caller must read issue_labels from that same
# issue. When the body marker is missing or names another issue, the PR is still followed
# up as #N (the fix round runs), but it is never auto-merged.
include "pr";
def trusted: . == $owner or . == "github-actions" or . == "github-actions[bot]";
def cr: . == "coderabbitai" or . == "coderabbitai[bot]";

.pr as $pr
| ($pr | branch_issue) as $issue
| ($pr | pr_issue != null) as $marker_ok
| ([$pr.comments[]? | select((.author.login | trusted) and ((.body // "") | contains("<!-- agent-fix-round -->")))] | length > 0) as $done
| ([$pr.reviews[]? | select(.author.login | cr)] | length > 0) as $cr_reviewed
| ((.now - ($pr.createdAt | fromdateiso8601)) / 60 >= $grace_minutes) as $grace_over
| (.issue_labels | index("risk:low") != null) as $low
| if $issue == null or $pr.isCrossRepository or $pr.state != "OPEN" then
    {agent_pr: false, issue: null, fix_round: false, auto_merge: false, reason: "not an open agent PR"}
  elif ($done | not) and ($cr_reviewed or $grace_over) then
    {agent_pr: true, issue: $issue, fix_round: true, auto_merge: false, reason: "reviews are in; run the single fix round"}
  elif $done | not then
    {agent_pr: true, issue: $issue, fix_round: false, auto_merge: false, reason: "waiting for CodeRabbit (grace period)"}
  elif $low and ($marker_ok | not) then
    {agent_pr: true, issue: $issue, fix_round: false, auto_merge: false,
     reason: "fix round done, risk:low, but the PR body's issue marker is missing or does not match the branch: left for the owner"}
  elif $low then
    {agent_pr: true, issue: $issue, fix_round: false, auto_merge: true, reason: "fix round done, risk:low"}
  else
    {agent_pr: true, issue: $issue, fix_round: false, auto_merge: false, reason: "fix round done, not risk:low: left for the owner"}
  end
