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

# release_reasons($now; $days): {commits: [commit_info], milestones: [{title, open_issues,
# closed_issues}]} -> [why a release is due]; [] when it is not.
#   (a) the oldest unreleased fix commit is more than $days days old ($now: epoch seconds)
#   (b) an open milestone has no open issues left (and at least one closed: a milestone
#       nobody has put anything in yet is not finished)
def release_reasons($now; $days):
  ([.commits[] | select(.type == "fix") | .date | select(. != null)] | min) as $oldest
  | [ (if $oldest != null and (($now - ($oldest | fromdateiso8601)) > ($days * 86400))
       then "the oldest unreleased fix landed on \($oldest[:10]), more than \($days) days ago" else empty end),
      (.milestones[] | select((.open_issues // 0) == 0 and (.closed_issues // 0) > 0)
       | "milestone \(.title | safe_line(80)) has no open issues left") ];

# grouped: [commit_info] -> [{prefix, commits}] : feat, fix, the other prefixes by name,
# then "other" (no conventional prefix).
def grouped:
  map(. + {prefix: (.type // "other")})
  | group_by(.prefix)
  | map({prefix: .[0].prefix, commits: .})
  | sort_by([(if .prefix == "feat" then 0 elif .prefix == "fix" then 1 elif .prefix == "other" then 3 else 2 end), .prefix]);

# existing_release($owner): [open issues {number, title, author, labels}] -> the owner's
# open release issue | null. Exact title, the owner as author AND the release label:
# an issue someone else opened with the same title is never touched.
def existing_release($owner):
  [.[] | select(((.title // "") | test("\\ARelease v[0-9]+\\.[0-9]+\\.[0-9]+\\z"))
                and .author.login == $owner
                and ([.labels[]?.name] | index("release") != null))]
  | sort_by(.number) | .[0];

# release_body($tag; $version; $reasons; $milestone; $slip): [commit_info] -> Markdown.
#   $milestone: the matching milestone | null     $slip: [open issue numbers in it]
# Commit text is not the owner's words: every piece goes through safe_line, sits inside
# a list item, and the whole body goes through defang_base.
def release_body($tag; $version; $reasons; $milestone; $slip):
  def capped($n): if length > $n then .[:$n] + ["- ...and \(length - $n) more"] else . end;
  def note_line: "- " + (if .scope != null and .scope != "" then "**\(.scope | safe_line(40)):** " else "" end) + (.desc | safe_line);
  def section($title; $lines): ["### \($title)", ""] + (if ($lines | length) > 0 then ($lines | capped(50)) else ["None."] end) + [""];
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
      + section("Fixes"; [$commits[] | select(.type == "fix") | note_line])
      + [ "## Commits since `\($tag)`", "" ]
      + ($commits | grouped | map(["**\(.prefix | safe_line(40))** (\(.commits | length))", ""]
                                  + ([.commits[] | "- `\(.sha[:7])` " + (.subject | safe_line)] | capped(50)) + [""]) | add // [])
      + [ "## Would slip", "" ]
      + [ if $milestone == null then
            "No open milestone is named `\($version)` (or `\($version | ltrimstr("v"))`, or the same without the patch number), so nothing is recorded as slipping."
          elif ($slip | length) == 0 then
            "Milestone **\($milestone.title | safe_line(80))** has no open issues."
          else
            "Still open in milestone **\($milestone.title | safe_line(80))**; these miss the release unless they land first: "
            + ($slip | sort | map("#\(.)") | join(", "))
          end ]
    ) | join("\n") | defang_base;

# release_decision($owner; $now; $days):
#   {tag: "vX.Y.Z" | null, commits: [{sha, message, date}] (default branch, since the tag),
#    milestones: [open milestones {number, title, open_issues, closed_issues}],
#    issues: [open issues {number, title, body, author, labels, milestone}]}
#   -> {action, note, version, title, body, issue, reasons}
#   action: "none"    nothing to do (note says why)
#           "create"  open a new issue        "update"  edit the body of issue
#           "retitle" the version changed: edit the title and body of issue
def release_decision($owner; $now; $days):
  def none($note): {action: "none", note: $note, version: null, title: null, body: null, issue: null, reasons: []};
  def norm: (. // "") | gsub("\r"; "") | sub("\n+\\z"; "");
  if .tag == null then none("no vX.Y.Z tag yet, so there is no version to count from")
  elif (.commits | length) == 0 then none("no commits since \(.tag)")
  else
    .tag as $tag
    | (.commits | map(commit_info)) as $commits
    | ($commits | next_version($tag)) as $version
    | "Release \($version)" as $title
    | ({commits: $commits, milestones: .milestones} | release_reasons($now; $days)) as $reasons
    | (.issues | existing_release($owner)) as $old
    | (.milestones | milestone_for($version)) as $ms
    | (if $ms == null then [] else [.issues[] | select(.milestone != null and .milestone.number == $ms.number) | .number] end) as $slip
    | ($commits | release_body($tag; $version; $reasons; $ms; $slip)) as $body
    | {action: "none", note: "", version: $version, title: $title, body: $body, issue: ($old.number // null), reasons: $reasons}
    | if $old == null and ($reasons | length) == 0 then
        none("\($commits | length) commit(s) since \($tag), but no fix older than \($days) days and no finished milestone")
      elif $old == null then .action = "create" | .note = "open \($title): \($reasons | join("; "))"
      elif $old.title != $title then .action = "retitle" | .note = "#\($old.number): \($old.title) becomes \($title)"
      elif ($old.body | norm) == ($body | norm) then .note = "#\($old.number) \($title) is up to date"
      else .action = "update" | .note = "#\($old.number) \($title): commit list refreshed"
      end
  end;
