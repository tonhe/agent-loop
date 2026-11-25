# Decide which of the owner's issues the backlog manager should look at.
# Input:  [ {number,title,body,labels,author,createdAt,comments:[{author,body,createdAt}]} ]
# Args:   --arg owner LOGIN  --argjson max N  --argjson open [open issue numbers]
#         --argjson native {"<issue number>": [open native blocker numbers]}   optional, default {}
#         --argjson parents {"<issue number>": native parent issue number}     optional, default {}
# Output: [ trimmed issues needing (re)assessment ]
# An issue needs assessment when it has no assessment comment yet, or the
# owner commented after the last assessment (comment "/reassess" to force it).
include "blocked";
include "meta";
include "glob";
include "paired";
# Blocked issues are skipped entirely; they become candidates once their blockers close.
# The Release and Plan issues the loop files itself (lib/meta.jq) are never candidates:
# their bodies are built from commit messages or written by the model, and what happens
# to them is the owner's decision. Not being candidates, they are also outside the
# allowed set of validate-plan.jq, so no plan can label them.
def is_assessment: (.body // "") | contains("<!-- agent-assessment -->");
# assessed_at: assessment comment -> when it was last written. apply-backlog.sh edits the
# one assessment comment in place, so its createdAt stays at the first run; the script
# therefore stamps the time of each write on the comment's second line:
#   <!-- agent-assessment -->
#   <!-- assessed-at 2026-11-25T16:35:25Z -->
# Only that exact place counts (anything further down is text the model wrote), and the
# stamp can only move the time forward from createdAt. Without a stamp it is createdAt.
def assessed_at:
  .createdAt as $c
  | ((.body // "") | capture("\\A<!-- agent-assessment -->\\r?\\n<!-- assessed-at (?<t>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z) -->") | .t) // $c
  | if . > $c then . else $c end;

($ARGS.named.native // {}) as $native
| ($ARGS.named.parents // {}) as $parents
| paired_epics($owner) as $epics
| [ .[]
  | select(.author.login == $owner)
  | select(issue_blocked($open; $native) | not)
  | select(is_meta_issue | not)
  | . as $i
  | ([.comments[] | select(.author.login == $owner and is_assessment)] | last) as $a
  | ([.comments[] | select(.author.login == $owner and (is_assessment | not))]) as $mine
  | select($a == null or (($a | assessed_at) as $at | [$mine[] | select(.createdAt > $at)] | length > 0))
  | {
      number, title, body,
      labels: [.labels[].name],
      # Blockers the body names that are closed now. A candidate is never blocked, so every
      # numbered blocker in its body is one of these. Without this fact the model reads
      # "Blocked by #4" in the body and triages the issue as if #4 were still open.
      closed_blockers: [(.body | blockers)[] | select(. > 0)],
      # Whether the owner has written an "Owner decision" comment on this issue (the test
      # in lib/glob.jq, the same one the review uses). apply-backlog.sh reads this fact
      # and validate-plan.jq then changes no label on the issue: triage may only comment.
      owner_decision: ((.comments // []) | owner_decisions($owner) | length > 0),
      # The open, owner-authored, agent:paired epic this issue is a sub-issue of, or null
      # (lib/paired.jq: the native parent link, or a body line starting "Part of #N").
      # apply-backlog.sh reads this fact and validate-plan.jq then labels the issue
      # agent:paired and routes it nowhere else.
      paired_parent: paired_parent($epics; $parents),
      owner_comments: [$mine[] | {createdAt, body}],
      previous_assessment: ($a.body // null)
    }
]
| sort_by(.number)
| .[:$max]
