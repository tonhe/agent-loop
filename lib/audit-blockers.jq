# Blocker audit: a blocker can be written in the issue body ("Blocked by #N",
# lib/blocked.jq) and recorded as a GitHub native dependency. The loop honours either,
# but GitHub's own display uses the native link only. These filters find where the two
# disagree and decide what scripts/audit-blockers.sh does about it. No model is involved.
#
# The audit has its own query and its own filters: nothing here feeds selection or
# triage (those use native-blockers.sh / lib/native-blockers.jq).
include "blocked";
include "meta";

# audit_issues($repo): slurped GraphQL pages of scripts/audit-blockers.sh ->
#   [{number, id, author, body, truncated,
#     native: [{number, state: "OPEN"|"CLOSED", local}]}]      (open issues only)
# id is the issue's database id as a string of digits (the REST API wants it, not the
# number). local: the native blocker is in this repository. truncated: the issue has
# more native blockers than the page that was fetched.
# Fails (non-zero exit) on an empty or error answer, so the caller can degrade.
def audit_issues($repo):
  if length == 0 or any(.[]; .errors != null or .data.repository.issues.nodes == null)
  then error("no usable dependency data")
  else
    [ .[].data.repository.issues.nodes[]
      | {number,
         id: ((.fullDatabaseId // "") | tostring),
         author: (.author.login // ""),
         body: (.body // ""),
         native: [.blockedBy.nodes[]?
                  | {number, state,
                     local: (((.repository.nameWithOwner // "") | ascii_downcase) == ($repo | ascii_downcase))}],
         truncated: ((.blockedBy.totalCount // 0) > ((.blockedBy.nodes // []) | length))} ]
  end;

# cross_refs: body -> numbers written as "owner/repo#N". blockers reads those as #N of
# this repository; the audit never links on such a number.
def cross_refs: [scan("[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#([0-9]+)") | .[0] | tonumber];

# direct_blockers: issue body -> the numbers it names plainly as blockers. A subset of
# blockers (lib/blocked.jq), which takes every #N in a "blocked by" sentence:
#   "Blocked by #4."  "Blocked by #4, #5 and #6."  "Blocked by: issue #4"   -> named plainly
#   "Blocked by the design issue under #6, and by #4."   -> 4 only (#6 is the parent)
#   "Blocked by #4 and by the diff issues from #16."     -> 4 only
#   "after #4 merges"                                    -> 4
# A number counts when it comes first in the sentence or right after "by", and then
# along a plain list ("#4, #5 and #6"). Only these are ever linked: a wrong native link
# blocks an issue until someone removes it by hand.
def direct_blockers:
  (. // "") as $b
  | [$b | scan("(?i)(?<!not )(?<![\"“])\\bblocked by\\b(?![\"”])([^.\\n]*)") | .[0]
     | scan("(?i)(?:\\A[\\s:*]*|\\bby\\s+)(?:issues?\\s+)?(#[0-9]+(?:(?:\\s*,\\s*(?:and\\s+)?|\\s+and\\s+|\\s+&\\s+)#[0-9]+)*)") | .[0]
     | scan("#([0-9]+)") | .[0] | tonumber]
    + [$b | scan("(?i)\\bafter #([0-9]+) (?:merges|lands|is merged|ships)") | .[0] | tonumber]
  | unique;

# audit_plan($owner; $max): output of audit_issues -> what to do.
#   add:      [{issue, blocker, id}]   native links to create (id = the blocker's database id)
#   over_cap: [{issue, blocker}]       would be added, but $max was reached
#   report:   [{issue, blocker, kind}] told to the owner, nothing written
#       kind "not_owner": the text names an open issue someone else wrote
#       kind "indirect":  an open issue appears in a "blocked by" sentence, but is not
#                         named plainly as the blocker (see direct_blockers)
#       kind "link_only": an open native blocker the text does not mention
#       kind "truncated": too many native blockers to compare (blocker is null)
#   skipped:  [{issue, blocker, why}]  left alone, for the job log only
#   checked:  number of issues audited
#
# Only open issues written by $owner are audited, and Release / Plan issues never.
# A link is planned only when the text names a number that has no native link of that
# number yet, and that number is an OPEN ISSUE of this repository (so not a closed
# issue, not a pull request, not a number that does not exist), written by $owner, not
# a Release / Plan issue, not the issue itself, not an "owner/repo#N" reference, and
# named plainly as the blocker (direct_blockers).
# Nothing is ever removed, and no issue body is ever changed.
def audit_plan($owner; $max):
  (map({key: (.number | tostring), value: .}) | from_entries) as $open
  | [.[] | select(.author == $owner and (is_meta_issue | not))] as $mine
  | [ $mine[] | . as $i
      | if .truncated then {t: "report", issue: .number, blocker: null, kind: "truncated"}
        else
          (.body | blockers) as $text
          | (.body | cross_refs) as $cross
          | (.body | direct_blockers) as $direct
          | ($text[] | . as $n
             | if   $n == -1                       then {t: "skipped", issue: $i.number, blocker: $n, why: "unnumbered"}
               elif any($i.native[]; .number == $n) then empty
               elif $n == $i.number                then {t: "skipped", issue: $i.number, blocker: $n, why: "self"}
               elif ($cross | index($n)) != null   then {t: "skipped", issue: $i.number, blocker: $n, why: "cross_repo"}
               else $open[$n | tostring] as $b
                 | if   $b == null             then {t: "skipped", issue: $i.number, blocker: $n, why: "not_open"}
                   elif ($direct | index($n)) == null
                                               then {t: "report",  issue: $i.number, blocker: $n, kind: "indirect"}
                   elif $b.author != $owner    then {t: "report",  issue: $i.number, blocker: $n, kind: "not_owner"}
                   elif ($b | is_meta_issue)   then {t: "skipped", issue: $i.number, blocker: $n, why: "meta"}
                   elif ($b.id | test("\\A[1-9][0-9]*\\z") | not)
                                               then {t: "skipped", issue: $i.number, blocker: $n, why: "no_id"}
                   else {t: "add", issue: $i.number, blocker: $n, id: $b.id}
                   end
               end),
            ($i.native[] | select(.state == "OPEN" and .local) | .number as $n
             | select(($text | index($n)) == null)
             | {t: "report", issue: $i.number, blocker: $n, kind: "link_only"})
        end ] as $all
  | ([$all[] | select(.t == "add") | del(.t)] | sort_by(.issue, .blocker)) as $adds
  | (if $max < 0 then 0 else $max end) as $cap
  | {checked: ($mine | length),
     add: $adds[:$cap],
     over_cap: ($adds[$cap:] | map({issue, blocker})),
     report: ([$all[] | select(.t == "report") | del(.t)] | sort_by(.issue, .blocker)),
     skipped: ([$all[] | select(.t == "skipped") | del(.t)] | sort_by(.issue, .blocker))};

# audit_text($max; $lines): {plan: <audit_plan output>, results: [{issue, blocker, status}]}
# -> the text for the digest, or "" when there is nothing to tell.
# status: "added" | "failed" | "dry" (dry run) | "report" (report-only mode).
# Issues appear as #N only, never as a URL (Discord turns URLs into preview cards).
# At most $lines detail lines; the rest is counted.
def audit_text($max; $lines):
  def n($count; $what): if $count > 0 then ["\($count) \($what)"] else [] end;
  .plan as $p | (.results // []) as $r
  | ( [$r[] | "- #\(.issue): " +
         (if   .status == "added"  then "link to #\(.blocker) added"
          elif .status == "failed" then "could not add the link to #\(.blocker), see the run log"
          elif .status == "dry"    then "would add the link to #\(.blocker) (dry run)"
          else "text names #\(.blocker), no link (report only, nothing added)" end)]
    + [$p.over_cap[] | "- #\(.issue): text names #\(.blocker), no link; not added, limit of \($max) per run"]
    + [$p.report[] | "- #\(.issue): " +
         (if   .kind == "not_owner" then "text names #\(.blocker), which is not your issue; no link added"
          elif .kind == "indirect"  then "its blocked-by sentence mentions #\(.blocker), but not plainly as the blocker; no link added"
          elif .kind == "link_only" then "linked to #\(.blocker), which its text does not mention"
          else "more linked blockers than could be read; not checked" end)] ) as $detail
  | if ($detail | length) == 0 then ""
    else
      ( n([$r[] | select(.status == "added")] | length; "added")
      + n([$r[] | select(.status == "dry")] | length; "would be added")
      + n([$r[] | select(.status == "failed")] | length; "failed")
      + n(([$r[] | select(.status == "report")] | length) + ($p.over_cap | length) + ($p.report | length); "to look at") ) as $counts
      | ["Blocker audit (text against native links): " + ($counts | join(", ")) + "."]
        + $detail[:$lines]
        + (if ($detail | length) > $lines then ["- and \(($detail | length) - $lines) more, see the run log"] else [] end)
      | join("\n")
    end;
