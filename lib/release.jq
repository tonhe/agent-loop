# Release issues: decide when a "Release vX.Y.Z" issue is due and what it says.
# Pure: every fact comes in as input or argument, the clock included.
# scripts/release-issue.sh fetches the data and applies the decision.
include "base";

# parse_version: "v1.2.3" -> [1,2,3]; anything else (v1, v1.2, v1.2.3-rc1, 1.2.3) -> null.
def parse_version:
  if type == "string"
  then (capture("\\Av(?<a>[0-9]+)\\.(?<b>[0-9]+)\\.(?<c>[0-9]+)\\z") // null)
       | if . == null then null else [(.a, .b, .c) | tonumber] end
  else null end;

# latest_tag: [tag names] -> the highest vX.Y.Z by version number | null.
def latest_tag: [.[] | select(parse_version != null)] | sort_by(parse_version) | last;

# safe_line($max): any text -> one line that is safe to put in an issue filed as the
# owner: control characters become spaces, an HTML comment cannot open (so no marker
# can be forged), "@name" cannot notify anyone, and the length is capped.
def safe_line($max):
  tostring
  | explode | map(if . < 32 or . == 127 then 32 else . end) | implode
  | gsub("<!--"; "&lt;!--")
  | gsub("@"; "@​")
  | sub("\\A +"; "") | sub(" +\\z"; "")
  | if length > $max then .[:$max] + "…" else . end;
def safe_line: safe_line(200);

# commit_info: {sha, message, date} ->
#   {sha, date, subject, type, scope, desc, breaking, notes}
#   type:     the conventional-commit prefix in lower case ("feat", "fix", ...) | null
#   scope:    the text in parentheses | null
#   desc:     the subject without its prefix (the whole subject when there is no prefix)
#   breaking: "!" after the type or scope, or a "BREAKING CHANGE:" line in the message
#   notes:    the text of every "BREAKING CHANGE:" line
def commit_info:
  ((.message // "") | split("\n") | map(sub("\r\\z"; ""))) as $lines
  | ($lines[0] // "") as $subject
  | ($subject
     | capture("\\A(?<type>[A-Za-z]+)(\\((?<scope>[^()]*)\\))?(?<bang>!)?:[ \\t]*(?<desc>.*)\\z")
       // null) as $c
  | [$lines[1:][] | capture("\\ABREAKING[ -]CHANGE:[ \\t]*(?<n>.*)\\z").n] as $notes
  | {sha: (.sha // ""), date: (.date // null), subject: $subject,
     type: (if $c == null then null else ($c.type | ascii_downcase) end),
     scope: (if $c == null then null else $c.scope end),
     desc: (if $c == null then $subject else $c.desc end),
     breaking: (($c != null and $c.bang != null) or ($notes | length) > 0),
     notes: $notes};

# bump: [commit_info] -> "minor" when any commit is a feat or breaking, else "patch".
# Every other prefix is a patch, enhance included: an enhancement (type:enhancement, #61)
# changes existing behaviour or output and ships in a patch release.
def bump: if any(.[]; .type == "feat" or .breaking) then "minor" else "patch" end;

# next_version($tag): [commit_info] -> "vX.Y.Z" after $tag ("vX.Y.Z").
def next_version($tag):
  ($tag | parse_version) as $v
  | if bump == "minor" then "v\($v[0]).\($v[1] + 1).0" else "v\($v[0]).\($v[1]).\($v[2] + 1)" end;

# next_minor: "vX.Y.Z" -> "vX.(Y+1)".
def next_minor: parse_version | "v\(.[0]).\(.[1] + 1)";

# milestone_for($version): [milestones {number, title}] -> the milestone whose title,
# trimmed, is exactly vX.Y.Z, X.Y.Z, vX.Y or X.Y for $version ("vX.Y.Z") | null.
# The full version is preferred over the X.Y form, then the lowest milestone number.
def milestone_for($version):
  ($version | parse_version) as $v
  | ["v\($v[0]).\($v[1]).\($v[2])", "\($v[0]).\($v[1]).\($v[2])", "v\($v[0]).\($v[1])", "\($v[0]).\($v[1])"] as $names
  | [.[] | ((.title // "") | sub("\\A[ \\t]+"; "") | sub("[ \\t]+\\z"; "")) as $t
         | ($names | index($t)) as $rank
         | select($rank != null) | {rank: $rank, m: .}]
  | sort_by([.rank, .m.number]) | .[0].m;

# release_reasons($now; $days; $version): {commits: [commit_info], milestones: [{number,
# title, open_issues, closed_issues}]} -> [why a release is due]; [] when it is not.
#   (a) the oldest unreleased fix or enhance commit is more than $days days old ($now:
#       epoch seconds). Both ship in a patch, so either one makes a patch release due.
#   (b) the open milestone for $version (milestone_for) has no open issues left (and at
#       least one closed: a milestone nobody has put anything in yet is not finished).
#       Only that milestone counts: a finished "Backlog cleanup" or a milestone for some
#       other version says nothing about the version being proposed.
def release_reasons($now; $days; $version):
  ([.commits[] | select(.type == "fix" or .type == "enhance") | .date | select(. != null)] | min) as $oldest
  | ((.milestones // []) | milestone_for($version)) as $ms
  | [ (if $oldest != null and (($now - ($oldest | fromdateiso8601)) > ($days * 86400))
       then "the oldest unreleased fix or enhancement landed on \($oldest[:10]), more than \($days) days ago" else empty end),
      ($ms | select(. != null) | select((.open_issues // 0) == 0 and (.closed_issues // 0) > 0)
       | "milestone \(.title | safe_line(80)) has no open issues left") ];

# grouped: [commit_info] -> [{prefix, commits}] : feat, enhance, fix, the other prefixes
# by name, then "other" (no conventional prefix).
def grouped:
  map(. + {prefix: (.type // "other")})
  | group_by(.prefix)
  | map({prefix: .[0].prefix, commits: .})
  | sort_by([(if .prefix == "feat" then 0 elif .prefix == "enhance" then 1 elif .prefix == "fix" then 2
               elif .prefix == "other" then 4 else 3 end), .prefix]);

# loop_release($owner): issue {title, body, author, labels} -> true when it is a release
# issue this loop filed: exact title, the owner as author, the release label AND the
# "<!-- agent-release -->" marker release_body puts in the body. All four.
def loop_release($owner):
  ((.title // "") | test("\\ARelease v[0-9]+\\.[0-9]+\\.[0-9]+\\z"))
  and .author.login == $owner
  and ([.labels[]?.name] | index("release") != null)
  and ((.body // "") | contains("<!-- agent-release -->"));

# existing_release($owner): [open issues {number, title, body, author, labels}] -> the
# open release issue the loop filed for the owner | null. An issue someone else opened
# with the same title is never touched, and neither is one the owner wrote by hand: it
# has no marker, so it is not ours to overwrite.
def existing_release($owner):
  [.[] | select(loop_release($owner))] | sort_by(.number) | .[0];

# handwritten_release($owner; $title): [open issues] -> the owner's open issue with
# exactly $title that the loop did not file | null. While it is open no second issue
# with that title is opened and none is retitled to it.
def handwritten_release($owner; $title):
  [.[] | select(.title == $title and .author.login == $owner and (loop_release($owner) | not))]
  | sort_by(.number) | .[0];

# release_body($tag; $version; $reasons; $milestone; $slip): [commit_info] -> Markdown.
#   $milestone: the matching milestone | null     $slip: [open issue numbers in it]
# Commit text is not the owner's words: every piece goes through safe_line, sits inside
# a list item, and the whole body goes through defang_base.
#
# Size: GitHub refuses an issue body over 65,536 characters, and the edit would fail
# every night from then on. The body is kept at or under release_body_limit: the draft
# notes are capped per section, and the commit list, the only part that grows without
# bound, is cut where it stops fitting and ends with one "…and N more" line. The marker
# on the first line and the Would slip section after the list are never cut.
def release_body_limit: 60000;
def release_body($tag; $version; $reasons; $milestone; $slip):
  def capped($n): if length > $n then .[:$n] + ["- ...and \(length - $n) more"] else . end;
  def note_line: "- " + (if .scope != null and .scope != "" then "**\(.scope | safe_line(40)):** " else "" end) + (.desc | safe_line);
  def section($title; $lines): ["### \($title)", ""] + (if ($lines | length) > 0 then ($lines | capped(50)) else ["None."] end) + [""];
  # Commit list entries: {s: line, c: 1 for a commit line, m: commits a "more" line stands for}.
  def entries:
    grouped
    | map((.commits | length) as $n
          | [{s: "**\(.prefix | safe_line(40))** (\($n))"}, {s: ""}]
            + [.commits[:50][] | {s: ("- `\(.sha[:7])` " + (.subject | safe_line)), c: 1}]
            + (if $n > 50 then [{s: "- ...and \($n - 50) more", m: ($n - 50)}] else [] end)
            + [{s: ""}])
    | add // [];
  def counted: map((.c // 0) + (.m // 0)) | add // 0;
  # fit($budget): entries -> the longest leading run whose lines, joined, take at most
  # $budget characters; when something had to go, headings left dangling at the end are
  # dropped and one line says how many commits are not listed.
  def fit($budget):
    . as $all
    | (reduce $all[] as $e ({n: 0, used: 0, full: false};
         if .full then .
         else (.used + ($e.s | length) + 1) as $u
           | if $u > $budget then .full = true else .n += 1 | .used = $u end
         end) | .n) as $n
    | if $n == ($all | length) then $all
      else ($all[:$n] | until(length == 0 or (.[-1].c // .[-1].m) != null; .[:-1])) as $kept
        | $kept + [{s: "- …and \(($all | counted) - ($kept | counted)) more commit(s) not listed here: the issue body would be too long"}, {s: ""}]
      end;
  . as $commits
  | ($commits | bump) as $bump
  | [$commits[] | select(.breaking)] as $breaking
  | ( [ "<!-- agent-release -->",
        "Proposed by the backlog run. Nothing has been tagged or released, and this issue never will: tag `\($version)` yourself when you are ready, then close this issue.",
        "",
        "- Previous tag: `\($tag)`",
        "- Commits since then: \($commits | length)",
        "- Version: `\($version)` (" + (if $bump == "minor" then "minor bump: there is a `feat` or a breaking change" else "patch bump: no `feat` and nothing breaking" end) + ")",
        "- Why now: " + (if ($reasons | length) > 0 then ($reasons | join("; ")) else "an earlier run opened this issue; neither trigger holds right now" end),
        "",
        "## Draft release notes",
        "" ]
      + section("Breaking"; [$breaking[] | note_line, (.notes[] | "  - " + safe_line)])
      + section("Features"; [$commits[] | select(.type == "feat") | note_line])
      + section("Enhancements"; [$commits[] | select(.type == "enhance") | note_line])
      + section("Fixes"; [$commits[] | select(.type == "fix") | note_line])
      + [ "## Commits since `\($tag)`", "" ]
    ) as $head
  | ( [ "## Would slip", "" ]
      + [ if $milestone == null then
            "No open milestone is named `\($version)` (or `\($version | ltrimstr("v"))`, or the same without the patch number), so nothing is recorded as slipping."
          elif ($slip | length) == 0 then
            "Milestone **\($milestone.title | safe_line(80))** has no open issues."
          else
            "Still open in milestone **\($milestone.title | safe_line(80))**; these miss the release unless they land first: "
            + ($slip | sort | map("#\(.)") | join(", "))
          end ]
    ) as $tail
  # What the list may take: the limit, less the other two parts, the joining newlines
  # and room for the "…and N more" line.
  | (release_body_limit - ($head | join("\n") | length) - ($tail | join("\n") | length) - 200) as $budget
  | ($head + ($commits | entries | fit($budget) | map(.s)) + $tail)
  | join("\n") | defang_base
  # Cannot happen with the caps above; if it ever does, the end goes, never the marker.
  | if length > release_body_limit then .[:release_body_limit] else . end;

# release_decision($owner; $now; $days):
#   {tag: "vX.Y.Z" | null, commits: [{sha, message, date}] (default branch, since the tag),
#    milestones: [open milestones {number, title, open_issues, closed_issues}],
#    issues: [open issues {number, title, body, author, labels, milestone}]}
#   -> {action, note, version, title, body, issue, reasons, notify}
#   action: "none"    nothing to do (note says why)
#           "create"  open a new issue        "update"  edit the body of issue
#           "retitle" the version changed: edit the title and body of issue
#   notify: true when "none" is something the owner should hear about in the digest:
#           an issue would have been opened or retitled, but the owner already has a
#           hand-written issue with that title. It is left exactly as it is.
def release_decision($owner; $now; $days):
  def none($note): {action: "none", note: $note, version: null, title: null, body: null, issue: null, reasons: [], notify: false};
  def norm: (. // "") | gsub("\r"; "") | sub("\n+\\z"; "");
  if .tag == null then none("no vX.Y.Z tag yet, so there is no version to count from")
  elif (.commits | length) == 0 then none("no commits since \(.tag)")
  else
    .tag as $tag
    | (.commits | map(commit_info)) as $commits
    | ($commits | next_version($tag)) as $version
    | "Release \($version)" as $title
    | ({commits: $commits, milestones: .milestones} | release_reasons($now; $days; $version)) as $reasons
    | (.issues | existing_release($owner)) as $old
    | (.issues | handwritten_release($owner; $title)) as $hand
    | (.milestones | milestone_for($version)) as $ms
    | (if $ms == null then [] else [.issues[] | select(.milestone != null and .milestone.number == $ms.number) | .number] end) as $slip
    | ($commits | release_body($tag; $version; $reasons; $ms; $slip)) as $body
    | {action: "none", note: "", version: $version, title: $title, body: $body, issue: ($old.number // null), reasons: $reasons, notify: false}
    | if $old == null and ($reasons | length) == 0 then
        none("\($commits | length) commit(s) since \($tag), but no fix older than \($days) days and no finished milestone for \($version)")
      elif $hand != null and ($old == null or $old.title != $title) then
        # Never a second issue with the owner's title, and never an edit of theirs.
        none("#\($hand.number) is titled \($title) but was not filed by the loop (it needs the `release` label and the loop's marker), so it is left alone and no second \($title) issue is "
             + (if $old == null then "opened" else "made by retitling #\($old.number)" end)
             + ". Close or rename #\($hand.number) to get the proposal")
        | .notify = true | .version = $version | .title = $title | .reasons = $reasons
      elif $old == null then .action = "create" | .note = "open \($title): \($reasons | join("; "))"
      elif $old.title != $title then .action = "retitle" | .note = "#\($old.number): \($old.title) becomes \($title)"
      elif ($old.body | norm) == ($body | norm) then .note = "#\($old.number) \($title) is up to date"
      else .action = "update" | .note = "#\($old.number) \($title): commit list refreshed"
      end
  end;
