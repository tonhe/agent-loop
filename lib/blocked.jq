# Dependency parsing shared by candidates.jq and select.jq.
#
# blockers: issue body -> array of issue numbers this issue waits on.
#   "Blocked by #4."                         -> [4]
#   "Blocked by the design issue under #6, and by #4." -> [6, 4]
#   "Do this after #4 merges"                -> [4]
#   "Blocked by the agent implementation issue." (no number) -> [-1]  (unknown: treat as blocked)
#   "this is not blocked by #4"              -> []
def blockers:
  (. // "") as $b
  | ([$b | scan("(?i)(?<!not )(?<![\"“])\\bblocked by\\b(?![\"”])([^.\\n]*)") | .[0]]
     | map([scan("#([0-9]+)") | .[0] | tonumber] | if length == 0 then [-1] else . end)
     | add // [])
    + [$b | scan("(?i)\\bafter #([0-9]+) (?:merges|lands|is merged|ships)") | .[0] | tonumber]
  | unique;

# is_blocked($open): true when any blocker is still open, or a blocker is unnamed.
def is_blocked($open):
  blockers | any(.[]; . as $n | $n == -1 or ($open | index($n)) != null);

# GitHub's native issue dependencies ("blocked by" in the issue sidebar).
# $native: {"<issue number>": [numbers of its OPEN native blockers]}, as printed by
# scripts/native-blockers.sh (built by lib/native-blockers.jq). Issues without an
# open native blocker are absent or map to []. {} means "no native data".
# native_blocked($native): issue object -> true when it has any open native blocker.
def native_blocked($native):
  (.number | tostring) as $k | (($native[$k] // []) | length) > 0;

# issue_blocked($open; $native): issue object -> blocked by EITHER the prose in its
# body or a native dependency.
def issue_blocked($open; $native):
  (.body | is_blocked($open)) or native_blocked($native);
