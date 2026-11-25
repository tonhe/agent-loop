# Pure decisions for sprint mode (skills/). The scripts gather facts; these decide.
#   paired_ready     which agent:paired issues a sprint may take (sprint-select.sh)
#   scope_paths      which files an issue says it touches (sprint-next.sh)
#   pick_parallel    which candidates can run next to the ones in flight (sprint-next.sh)
#   scope_check      may a work-issue subagent go on with this diff? (scope-check.sh)
#   report_problems  is a subagent's report acceptable? (check-report.sh)
include "blocked";
include "pr";
include "meta";
include "glob";
include "merge-gate";

def label_names: [(.labels // [])[].name];

# ---------- selection ----------

# busy_issues($owner): [open PRs] -> issue numbers that have an open loop PR. The same
# rule as lib/select.jq: the owner's PR, not from a fork, on branch issue-N.
def busy_issues($owner):
  map(select(.isCrossRepository == false and .author.login? == $owner) | branch_issue | values);

# paired_ready($owner; $milestone; $open; $native): {issues, prs} -> [numbers], oldest first.
# agent:paired issues are never in the nightly selection. A sprint may take the ones in
# its finish-line milestone (by exact title), under the same filters as select.jq
# otherwise: the owner's, not in progress, not needs:human, not a Release or Plan issue,
# not blocked, no open loop PR. No milestone given: none.
def paired_ready($owner; $milestone; $open; $native):
  (.prs | busy_issues($owner)) as $busy
  | if ($milestone // "") == "" then [] else
    [ .issues[]
      | select(.author.login == $owner)
      | select(label_names | index("agent:paired") != null)
      | select(label_names | (index("agent:in-progress") == null and index("needs:human") == null))
      | select((.milestone.title? // "") == $milestone)
      | select(is_meta_issue | not)
      | select(issue_blocked($open; $native) | not)
      | select(.number as $n | $busy | index($n) | not) ]
    | sort_by(.createdAt) | map(.number) end;

# ---------- scope and overlap ----------

# scope_paths: text -> the file and directory paths it names. A path is a token, bare or
# in backticks, that contains a "/" or is a file name with a common source, config or
# doc extension (or Makefile, Dockerfile). A trailing ":123" (file:line) and trailing
# punctuation are dropped. URLs, #N and plain words are not paths. Sorted, unique.
def code_ext: "\\.(go|mod|sum|js|mjs|cjs|ts|tsx|jsx|py|rb|rs|c|h|cc|cpp|hpp|java|kt|swift|sh|bash|jq|md|yml|yaml|json|toml|txt|sql|proto|lock|cfg|ini|conf|html|css|scss|vue|svelte|tf|nix|golden)\\z";
def scope_paths:
  [ (. // "") | gsub("[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+"; " ") | gsub("https?://[^\\s)>]*"; " ") | scan("(?:^|[\\s`(\\[\"'])((?:\\./)?[A-Za-z0-9_.@-]+(?:/[A-Za-z0-9_.@*-]+)*/?)") | .[0]
    | sub(":[0-9]+(?:[-:][0-9]+)?\\z"; "") | sub("[.,;:)]+\\z"; "") | sub("\\A\\./"; "")
    | select((test("/") and (test("\\A/+\\z") | not)) or test(code_ext) or test("\\A(Makefile|Dockerfile|GNUmakefile)\\z"))
  ] | unique;

# issue_scope: issue {body, comments} + $owner -> paths named in the body, in the
# owner's comments, and in the loop's assessment comment (which is posted as the owner).
def issue_scope($owner):
  ([.body] + [(.comments // [])[] | select(.author.login == $owner) | .body]) | map(scope_paths) | add // [] | unique;

# paths_overlap($a; $b): true when a path in one list is the same as, or a directory
# above, a path in the other. "internal/probe" overlaps "internal/probe/family.go".
def paths_overlap($a; $b):
  def norm: sub("/+\\z"; "");
  any($a[] | norm; . as $x | any($b[] | norm; . as $y | $x == $y or ($y | startswith($x + "/")) or ($x | startswith($y + "/"))));

# pick_parallel($limit): {in_flight: [{issue, paths}], candidates: [{issue, paths}]} ->
# the candidates to start now, in candidate order: as many as fit under $limit (in-flight
# ones included), none overlapping an in-flight issue or another pick. An issue whose
# scope names no path could touch anything, so it runs only when nothing else is in
# flight or picked, and nothing is picked next to it.
def pick_parallel($limit):
  def unknown: (.paths | length) == 0;
  reduce .candidates[] as $c ({taken: .in_flight, picks: [], skipped: []};
    if (.taken | length) >= $limit then .skipped += [{issue: $c.issue, why: "parallel limit"}]
    elif ($c | unknown) and (.taken | length) > 0 then .skipped += [{issue: $c.issue, why: "names no files, so it runs alone"}]
    elif any(.taken[]; unknown) then .skipped += [{issue: $c.issue, why: "an issue that names no files is in flight"}]
    elif any(.taken[]; paths_overlap(.paths; $c.paths)) then
      .skipped += [{issue: $c.issue, why: "files overlap #\([.taken[] | select(paths_overlap(.paths; $c.paths)) | .issue] | map(tostring) | join(", #"))"}]
    else .taken += [$c] | .picks += [$c] end)
  | {start: .picks, skipped: .skipped};

# ---------- work-issue: may the subagent go on? ----------

# scope_check($owner; $globs): {files, protected_hits, comments} -> {ok, protected,
# process, needs_decision}. protected: protected_paths hits (the agent may never change
# them; check-diff.sh would discard the change). process: the loop's own process files.
# needs_decision: protected_review_paths files with no Owner decision on the issue. The
# subagent stops on any of them: comment, needs:human, release the claim.
def scope_check($owner; $globs):
  . as $in
  | ({files: ($in.files // []), comments: ($in.comments // [])} | review_protected($globs; $owner)) as $rp
  | { protected: ($in.protected_hits // []),
      process: [($in.files // [])[] | select(glob_hit(process_patterns) != null)],
      needs_decision: (if $rp.status == "no_decision" then [$rp.matched[].file] else [] end),
      decision_scope: (if $rp.status == "check_scope" then [$rp.matched[].file] else [] end) }
  | .ok = ((.protected + .process + .needs_decision) | length == 0);

# ---------- the subagent's report ----------

# report_problems($repo): report -> [problems]; empty means accepted.
# A report: {issue: N, status: "pr_opened"|"stopped", pr: "https://github.com/R/pull/M",
#   summary: "...", noted: [{title, issue: "https://github.com/R/issues/K" | null}],
#   live_check: null | {commands: "...", why: "..."}}
# Rules: every noted item has a filed issue URL in this repository (nothing "noted but
# not filed"); pr_opened has a PR URL in this repository; references are full URLs, never
# a bare #N (chat output must name owner/repo); a stopped report says why.
def report_problems($repo):
  ("https://github.com/" + $repo) as $base
  | def url_of($kind): type == "string" and test("\\A" + ($base | gsub("(?<c>[.\\-])"; "\\\(.c)")) + "/" + $kind + "/[1-9][0-9]*\\z");
    . as $r
  | [ (if ($r.issue | type) != "number" then "issue is not a number" else empty end),
      (if ($r.status != "pr_opened" and $r.status != "stopped") then "status must be pr_opened or stopped" else empty end),
      (if $r.status == "pr_opened" and (($r.pr // null) | url_of("pull") | not) then "pr_opened without a full PR URL in \($repo)" else empty end),
      (if $r.status == "stopped" and (($r.summary // "") | length) == 0 then "stopped without saying why" else empty end),
      (($r.noted // [])[] | select((.issue // null) | url_of("issues") | not)
        | "noted but not filed: \(.title // "(untitled)" | tojson); file it with file-found.sh and put the issue URL in the report"),
      ([($r.summary // ""), (($r.noted // [])[] | .title // ""), ($r.live_check.why? // "")]
        | map(gsub("https?://[^\\s)>]*"; " ") | gsub("&#[0-9]+;"; " ")
              | scan("(?:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[0-9]+")) | unique
        | if length > 0 then "bare issue references \(join(", ")): use full https://github.com/\($repo)/... URLs" else empty end),
      (if ($r.live_check != null) and (($r.live_check.commands? // "") | length) == 0 then "live_check without the exact commands" else empty end)
    ];
