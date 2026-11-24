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
# and Markdown heading or emphasis marks allowed). Comments the loop posts as the owner
# (assessments, hand-backs) carry an "<!-- agent-" marker and never count.
def owner_decisions($owner):
  [.[] | select(.author.login == $owner) | (.body // "")
       | select(test("\\A[ \\t\\r\\n#*_]*Owner decision") and (contains("<!-- agent-") | not))];

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
def review_protected($globs; $owner):
  ($globs | glob_patterns) as $patterns
  | if ($patterns | length) == 0 then {status: "off", matched: [], decisions: []}
    else
      [.files[] | . as $f
        | (if startswith("\"") then "(unusual file name)" else glob_hit($patterns) end) as $g
        | select($g != null) | {file: $f, glob: $g}] as $matched
      | ((.comments // []) | owner_decisions($owner)) as $decisions
      | {status: (if ($matched | length) == 0 then "clear"
                  elif ($decisions | length) == 0 then "no_decision"
                  else "check_scope" end),
         matched: $matched, decisions: $decisions}
    end;
