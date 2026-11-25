# Which issues are sub-issues of an agent:paired epic. Used by candidates.jq; the model
# is never asked.
#
# part_of: issue body -> issue numbers the body says it is part of, in body order.
# A line counts when it STARTS with "Part of #N" (optionally inside ** or __ markup):
#   "Part of #5. Blocked by #4."      -> [5]
#   "**Part of #5.**"                 -> [5]
#   "> Part of #5."  (quoted)         -> []
#   "This is not part of #5."         -> []
#   "- Part of #5", "  Part of #5", "part of #5", "Part of the epic (#5)" -> []
# Only the number right after "Part of " is read; later #refs on the line are not.
def part_of:
  [ (. // "") | split("\n")[]
    | capture("^(?:\\*\\*|__)?Part of #(?<n>[0-9]+)") | .n | tonumber ];

# paired_epics($owner): list of open issues -> numbers of the owner's issues that carry
# agent:paired. The input is the open list, so a closed epic is never in the result.
def paired_epics($owner):
  [ .[] | select(.author.login == $owner and any(.labels[]?; .name == "agent:paired")) | .number ];

# paired_parent($epics; $parents): issue object -> the number of the paired epic it is a
# sub-issue of, or null.
# $parents: {"<issue number>": native parent number}, as printed by scripts/native-parents.sh
# ({} means "no native data"). The native parent is looked at first, then the "Part of #N"
# lines; the first one that is in $epics wins. An issue is never its own parent.
def paired_parent($epics; $parents):
  . as $i
  | [ ($parents[($i.number | tostring)] | numbers), ($i.body | part_of[]) ]
  | map(select(. as $n | $n != $i.number and ($epics | index($n)) != null))
  | .[0] // null;
