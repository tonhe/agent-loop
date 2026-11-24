# Decide which of the owner's issues the backlog manager should look at.
# Input:  [ {number,title,body,labels,author,createdAt,comments:[{author,body,createdAt}]} ]
# Args:   --arg owner LOGIN  --argjson max N  --argjson open [open issue numbers]
# Output: [ trimmed issues needing (re)assessment ]
# An issue needs assessment when it has no assessment comment yet, or the
# owner commented after the last assessment (comment "/reassess" to force it).
include "blocked";
# Blocked issues are skipped entirely; they become candidates once their blockers close.
def is_assessment: (.body // "") | contains("<!-- agent-assessment -->");

[ .[]
  | select(.author.login == $owner)
  | select(.body | is_blocked($open) | not)
  | . as $i
  | ([.comments[] | select(.author.login == $owner and is_assessment)] | last) as $a
  | ([.comments[] | select(.author.login == $owner and (is_assessment | not))]) as $mine
  | select($a == null or ([$mine[] | select(.createdAt > $a.createdAt)] | length > 0))
  | {
      number, title, body,
      labels: [.labels[].name],
      owner_comments: [$mine[] | {createdAt, body}],
      previous_assessment: ($a.body // null)
    }
]
| sort_by(.number)
| .[:$max]
