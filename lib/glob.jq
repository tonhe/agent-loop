# Path globs for protected-by-instruction paths (review workflow input
# protected_review_paths) and the "Owner decision" check that goes with them.
#
# Syntax, one pattern per line; blank lines and lines starting with # are ignored:
#   *      any run of characters within one path component (never crosses a /)
#   ?      one character, not a /
#   **     any run of characters, / included; "a/**/b" also matches "a/b"
#   other characters match themselves (no [classes], no {a,b}, no ! negation)
# A pattern is anchored at the repository root and must match the whole path, except
# that a pattern which matches a directory also matches everything under it. So
# "internal/sysprobe/", "internal/sysprobe" and "internal/sysprobe/**" protect the same
# files. A leading "./" or "/" and a trailing "/" are dropped. Matching is case-sensitive.

# glob_patterns: text -> [patterns], cleaned as described above.
def glob_patterns:
  (. // "") | split("\n")
  | map(sub("\r\\z"; "") | sub("\\A[ \\t]+"; "") | sub("[ \\t]+\\z"; "")
        | select(. != "" and (startswith("#") | not))
        | sub("\\A(\\./)+"; "") | sub("\\A/+"; "") | sub("/+\\z"; "")
        | select(. != ""));

# glob_regex: one cleaned pattern -> regex source. [\s\S], not ".": a file name may
# contain a newline, and "." would stop there.
def glob_regex:
  "\\A"
  + ([match("\\*\\*/|\\*\\*|\\*|\\?|[^*?]+"; "g").string
      | if . == "**/" then "([\\s\\S]*/)?"
        elif . == "**" then "[\\s\\S]*"
        elif . == "*" then "[^/]*"
        elif . == "?" then "[^/]"
        else gsub("(?<c>[\\\\.+()\\[\\]{}^$|])"; "\\\(.c)") end]
     | join(""))
  + "(/[\\s\\S]*)?\\z";

# glob_hit($patterns): path -> the first pattern that matches it | null.
def glob_hit($patterns):
  . as $path | [$patterns[] | select(. as $p | $path | test($p | glob_regex))] | .[0];

# owner_decisions($owner): [issue comments {author: {login}, body}] -> [bodies] of the
# comments written by the owner that begin with "Owner decision" (leading whitespace
# and Markdown heading or emphasis marks allowed). The phrase must end there: after it,
# and after any closing emphasis marks, comes a colon, blank space or the end of the
# comment. "Owner decisions are pending" and "Owner decision-making" are not decisions.
# Comments the loop posts as the owner (assessments, hand-backs) carry an "<!-- agent-"
# marker and never count.
def owner_decisions($owner):
  [.[] | select(.author.login == $owner) | (.body // "")
       | select(test("\\A[ \\t\\r\\n#*_]*Owner decision[*_]*(:|[ \\t\\r\\n]|\\z)") and (contains("<!-- agent-") | not))];

# review_protected($globs; $owner):
#   {files: [changed paths, as git prints them], comments: [issue comments]}
#   $globs: the protected_review_paths text
#   -> {status, matched: [{file, glob}], decisions: [comment bodies]}
#   status: "off"          no patterns: the feature is not in use
#           "clear"        no changed file is protected
#           "no_decision"  protected files changed and the owner approved nothing: block
#           "check_scope"  protected files changed and there is an Owner decision comment:
#                          the review model judges whether the diff stays within it
# git prints a name containing a quote, a backslash or a control character in C-quoted
# form ("..."); such a name cannot be matched reliably, so it counts as protected.
def protected_matches($patterns):
  [.[] | . as $f
    | (if startswith("\"") then "(unusual file name)" else glob_hit($patterns) end) as $g
    | select($g != null) | {file: $f, glob: $g}];

def review_protected($globs; $owner):
  ($globs | glob_patterns) as $patterns
  | if ($patterns | length) == 0 then {status: "off", matched: [], decisions: []}
    else
      (.files | protected_matches($patterns)) as $matched
      | ((.comments // []) | owner_decisions($owner)) as $decisions
      | {status: (if ($matched | length) == 0 then "clear"
                  elif ($decisions | length) == 0 then "no_decision"
                  else "check_scope" end),
         matched: $matched, decisions: $decisions}
    end;

# ---------- owner mode ----------
# An owner PR is not the loop's work, and its body may be model text, so here nothing
# is approved and nothing is blocked: the protected files the PR changes are listed for
# the owner, next to any "Owner decision" comments found on the owner's linked issues.
#
# owner_protected($globs; $owner):
#   {files: [changed paths, as git prints them], issues: [{number, comments}]}
#   -> {status, matched: [{file, glob}], decisions: [{issue, body}]}
#   status: "off"     no patterns
#           "clear"   no changed file is protected
#           "listed"  protected files changed
# matched does not depend on decisions in any way: a decision comment never takes a file
# off the list. issues are the ones review-linked.sh accepted (opened by the owner, not
# a Release or Plan issue); owner_decisions keeps only the owner's own comments.
def owner_protected($globs; $owner):
  ($globs | glob_patterns) as $patterns
  | if ($patterns | length) == 0 then {status: "off", matched: [], decisions: []}
    else
      ((.files // []) | protected_matches($patterns)) as $matched
      | [(.issues // [])[] | .number as $n | (.comments // []) | owner_decisions($owner)[] | {issue: $n, body: .}] as $decisions
      | {status: (if ($matched | length) == 0 then "clear" else "listed" end), matched: $matched, decisions: $decisions}
    end;

# owner_protected_section: the result above -> Markdown for the posted review and for
# the review prompt; "" unless files are listed. Written here, not by the model. File
# names come from the PR: shown in code spans, with backticks replaced. A decision is
# quoted (at most 1,500 characters each, at most 10) under the number of its issue.
def owner_protected_section:
  def code: "`" + gsub("`"; "'") + "`";
  def quote: (if length > 1500 then .[:1500] + " …(cut)" else . end)
    | gsub("<!--"; "&lt;!--") | split("\n") | map("> " + sub("\r\\z"; "")) | join("\n");
  if .status != "listed" then ""
  else
    (["#### Protected paths",
      "This PR changes files that are protected by instruction (`protected_review_paths`). On an owner PR nothing is blocked and nothing here counts as approval: the files are listed for the owner to judge.",
      (.matched | map("- " + (.file | code) + " (protected by " + (.glob | code) + ")") | join("\n"))]
     + (if (.decisions | length) == 0 then
          ["No \"Owner decision\" comment by the owner was found on a linked issue."]
        else
          ["\"Owner decision\" comments by the owner on the linked issue(s), quoted for the owner to judge. They were not checked against the diff and do not approve it:"]
          + (.decisions[:10] | map("From #\(.issue):\n\n" + (.body | quote)))
          + (if (.decisions | length) > 10 then ["(\((.decisions | length) - 10) more not shown)"] else [] end)
        end))
    | join("\n\n")
  end;
