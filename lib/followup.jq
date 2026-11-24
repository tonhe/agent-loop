# Decide what the follow-up job should do with one agent PR.
# Input:  {"pr": gh pr view JSON (number,body,createdAt,headRepositoryOwner,isCrossRepository,
#                state,comments,reviews), "now": epoch seconds,
#          "issue_labels": [names of linked issue]}
# Args:   --arg owner LOGIN  --argjson grace_minutes N
# Output: {"agent_pr": bool, "issue": N|null, "fix_round": bool, "auto_merge": bool, "reason": "..."}
def trusted: . == $owner or . == "github-actions" or . == "github-actions[bot]";
def cr: . == "coderabbitai" or . == "coderabbitai[bot]";

.pr as $pr
| ($pr.body // "" | [scan("agent-loop issue=([0-9]+)")[] | tonumber] | first) as $issue
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
  elif $low then
    {agent_pr: true, issue: $issue, fix_round: false, auto_merge: true, reason: "fix round done, risk:low"}
  else
    {agent_pr: true, issue: $issue, fix_round: false, auto_merge: false, reason: "fix round done, not risk:low: left for the owner"}
  end
