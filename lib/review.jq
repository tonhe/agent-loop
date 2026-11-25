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

# ---------- large PRs: what one part of a split review is told ----------
# scope_section($i; $max_list): lib/split.jq's plan -> Markdown for the prompt of group
# $i: which part this is, and the paths of the other parts, so the model knows what it is
# not seeing. At most $max_list paths are listed; the rest are counted. "" when the
# review is one call. Paths come from the PR: one line each, in a code span.
def scope_section($i; $max_list):
  def code: tostring | gsub("`"; "'") | explode | map(if . < 32 or . == 127 then 32 else . end) | implode | "`" + . + "`";
  (.groups | length) as $n
  | if $n < 2 then ""
    else
      .groups[$i] as $me
      | [ .groups | to_entries[] | select(.key != $i) | .key as $k | .value.paths[] | {part: ($k + 1), path: .} ] as $others
      | [ "## Scope of this review",
          "This pull request is large (\(.total_files) files, \(.total_lines) changed lines), so it is reviewed in \($n) parts, each by a separate reviewer. "
          + "This is part \($i + 1) of \($n): " + ($me.name | code) + " (\($me.files) files, \($me.lines) changed lines). "
          + "Only this part's diff is below. Judge this part, and report findings only for files in it.",
          "The files of the other parts are listed here so that you know what you are not seeing. They are reviewed separately; read them when you need them to understand this part:",
          ( $others[:$max_list] | group_by(.part)
            | map("Part \(.[0].part):\n" + (map("- " + (.path | code)) | join("\n"))) | join("\n\n") ) ]
        + (if ($others | length) > $max_list then ["(\(($others | length) - $max_list) more file(s) not listed.)"] else [] end)
      | join("\n\n")
    end;

# ---------- the posted review ----------
# Loop reviews and owner reviews carry different markers on their first line, so one can
# never be taken for the other. "<!-- agent-review -->" is not a substring of the owner
# marker.
def review_marker($mode): if $mode == "owner" then "<!-- agent-review-owner -->" else "<!-- agent-review -->" end;

# valid_review: is this what schemas/review.json asks for? Anything else (a timeout
# stub, null, a string) is a failed call, never a pass.
def valid_review:
  type == "object"
  and (.verdict == "pass" or .verdict == "block")
  and (.summary | type) == "string"
  and (.findings | type) == "array"
  and all(.findings[];
        type == "object"
        and (.severity == "blocking" or .severity == "minor")
        and (.comment | type) == "string"
        and (.file == null or (.file | type) == "string")
        and (.line == null or (.line | type) == "number"));

# Model text in a comment: no HTML comment can open, so no "<!-- agent-..." marker
# (review, fix round) can be planted for followup or for the comment lookup below.
def _model: tostring | defang_markers;
# Text from the PR or the model inside a code span: one line, no backtick.
def _code: tostring | gsub("`"; "'") | explode | map(if . < 32 or . == 127 then 32 else . end) | implode | "`" + . + "`";

# Why a call gave no review. rc is run-claude.sh's exit code as text ("" = never ran,
# "125" = review-calls.sh did not start it).
def _why:
  if .rc == "0" then "returned something that is not a review"
  elif .rc == "124" then "ran into the time limit"
  elif .rc == "3" then "ran into the turn limit"
  elif .rc == "125" then "was not started: the job's time budget was used up"
  elif (.rc // "") == "" then "did not run"
  elif (.rc | test("\\A[0-9]{1,3}\\z")) then "failed (exit \(.rc))"
  else "failed" end;

def _finding:
  "- **\(.severity)** "
  + (if .file then ((.file + (if .line then ":\(.line)" else "" end)) | _code) + " " else "" end)
  + (.comment | _model);

# review_combine: everything known after the Claude calls -> the one comment to post.
#   {mode: "loop"|"owner",
#    plan: lib/split.jq's plan (paths not needed) | null when no plan was made,
#    calls: [{rc, result, truncated}], one per plan group, in order,
#    protected: owner mode's script-written protected-path section ("" = none),
#    linked: [issue numbers used as context] | null (owner mode),
#    head: short commit id | ""}
#   -> {verdict: "pass"|"block"|"none", complete, failed: [group names], body}
#
# A group counts when its call exited 0 and returned a valid review. The verdict is the
# worst of the groups that count: "block" if any blocks, "pass" if all of them pass,
# "none" if no group counts. complete is true only when every group counts. Whether an
# incomplete or blocking review fails the job is the caller's rule (review-post.sh):
# always in loop mode, never in owner mode.
# One group gives the comment the loop has always posted. Several give a part per group
# and one merged list of findings, each finding with its file and line.
def review_combine:
  .mode as $mode
  | (.plan // {}) as $plan
  | (.calls // []) as $calls
  | [ ($plan.groups // []) | to_entries[]
      | (.value + ($calls[.key] // {rc: "", result: null})) as $c
      | $c + {ok: (($c.rc // "") == "0" and ($c.result | valid_review))} ] as $g
  | ($g | map(select(.ok))) as $ok
  | ($g | length) as $n
  | ($n > 0 and ($ok | length) == $n) as $complete
  | (if ($ok | length) == 0 then "none" elif any($ok[]; .result.verdict == "block") then "block" else "pass" end) as $verdict
  | (if $verdict == "none" then "NOT COMPLETED"
     else ($verdict | ascii_upcase) + (if $complete then "" else " (INCOMPLETE)" end) end) as $headline
  | "The diff for this part was cut at the size limit, so the reviewer did not see all of it." as $cutnote
  | ( [ review_marker($mode) + "\n### Agent review" + (if $mode == "owner" then " (advisory)" else "" end) + ": " + $headline ]
      + (if $mode == "owner" then
           [ "This review is advisory. It is posted for the owner to read, and the check passes whatever it says."
             + (if (.head // "") != "" then " Reviewed at commit " + (.head | _code) + "." else "" end),
             (if (.linked // []) | length > 0 then "Reviewed against linked issue(s) " + (.linked | map("#\(.)") | join(", ")) + "."
              else "No usable linked issue: reviewed on the diff alone." end) ]
           + (if (.protected // "") != "" then [.protected | sub("\\s+\\z"; "")] else [] end)
         else [] end)
    ) as $head
  | ( if $n == 0 then
        ["The review could not be completed: no review was produced for this push. The workflow run has the reason."]
      elif $n == 1 then
        ($g[0] | if .ok then
                   [.result.summary | _model]
                   + (if .truncated then ["The diff was cut at the size limit, so the reviewer did not see all of it."] else [] end)
                   + (if (.result.findings | length) > 0 then [.result.findings | map(_finding) | join("\n")] else [] end)
                 else ["The review could not be completed: the reviewer \(_why)."] end)
      else
        [ "Large PR: \($plan.total_files) files, \($plan.total_lines) changed lines, reviewed in \($n) parts."
          + (if $plan.capped then " The split came to \($plan.uncapped) parts; the smallest were merged to stay within the limit of \($n) calls, so some parts are larger than the split thresholds." else "" end) ]
        + [ $g | to_entries[] | .key as $i | .value
            | "#### Part \($i + 1) of \($n): " + (.name | _code) + ": "
              + (if .ok then (.result.verdict | ascii_upcase) else "NOT REVIEWED" end) + "\n\n"
              + "(\(.files) files, \(.lines) changed lines)\n\n"
              + (if .ok then (.result.summary | _model) else "The reviewer \(_why)." end)
              + (if .truncated then "\n\n" + $cutnote else "" end) ]
        + ( [$ok[] | .result.findings[] | _finding] as $f
            | if ($f | length) > 0 then ["#### Findings\n\n" + ($f | join("\n"))] else [] end )
        + (if $complete then [] else
             ["\($n - ($ok | length)) of \($n) parts could not be reviewed: " + ($g | map(select(.ok | not) | .name | _code) | join(", ")) + "."] end)
      end
    ) as $rest
  | ($head | join("\n\n")) as $h
  | ($rest | join("\n\n")) as $r
  | { verdict: $verdict, complete: $complete,
      failed: ($g | map(select(.ok | not) | .name)),
      body: (if ($h | length) + ($r | length) + 2 <= 60000 then $h + "\n\n" + $r
             else $h + "\n\n" + $r[:([60000 - ($h | length) - 200, 0] | max)] + "\n\n(The review text was cut to fit one comment.)" end) };

# existing_review_comment($marker): [{id, login, body}] (the PR's comments, oldest
# first) -> the id of the comment an owner review updates | null (create one).
# It must be written by github-actions[bot] and begin with the marker, so a comment by
# anyone else that quotes or copies the marker, a loop review and a fix-round comment are
# never overwritten. The oldest match wins, so the same comment is updated every time.
def existing_review_comment($marker):
  [ .[] | select(.login == "github-actions[bot]" and ((.body // "") | startswith($marker)) and (.id | type) == "number") | .id ]
  | .[0] // null;
