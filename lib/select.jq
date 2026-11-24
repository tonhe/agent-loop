# Pick issues the dev agent may work on tonight.
# Input:  {"issues": [gh issue list JSON], "prs": [gh pr list JSON]}
# Args:   --arg owner LOGIN  --argjson max N  --argjson open [open issue numbers]
# Output: [issue numbers]
include "blocked";
def names: [.labels[].name];
def has($l): names | index($l) != null;

([.prs[].body // "" | [scan("agent-loop issue=([0-9]+)")[] | tonumber]] | add // []) as $busy
| [ .issues[]
    | select(.author.login == $owner)
    | select(has("agent:ready"))
    | select(has("agent:in-progress") | not)
    | select(has("needs:human") | not)
    | select(.body | is_blocked($open) | not)
    | select(.number as $n | $busy | index($n) | not)
  ]
| sort_by(.createdAt)
| .[:$max]
| map(.number)
