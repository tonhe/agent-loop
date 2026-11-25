# Review workflow logic that is not about paths: which issues an owner PR links, how the
# per-group results become one comment, and which existing comment an owner review updates.
include "meta";

# ---------- owner mode: linked issues ----------
# linked_issues: PR body (text or null) -> [issue numbers], in order of first mention,
# no duplicates, at most $max.
# A link is one of GitHub's closing words, or Ref/Refs, then an optional colon, blanks
# on the same line, and "#N": "Fixes #12", "closes: #3", "Refs #40". Any case.
# Only "#N" of this repository: "org/repo#5" and issue URLs are not links. N is a plain
# positive number of at most 9 digits with no leading zero, and nothing word-like may
# follow it. The PR body may be model text; nothing but these numbers is taken from it.
def linked_issues($max):
  [ (. // "") | tostring
    | match("(?<![0-9A-Za-z_])(?:fix(?:e[sd])?|close[sd]?|resolve[sd]?|refs?):?[ \\t]+#([1-9][0-9]{0,8})(?![0-9A-Za-z_])"; "gi")
    | .captures[0].string | tonumber ]
  | reduce .[] as $n ([]; if index($n) != null then . else . + [$n] end)
  | .[:$max];
def linked_issues: linked_issues(5);
