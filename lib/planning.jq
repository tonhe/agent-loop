# Milestone planning: decide WHEN a "Plan vX.Y" issue is due (plan_due) and turn the
# backlog manager's proposal into the issue body (plan_body). What to propose is the
# model's judgement; when to ask, which issues it may name and what the issue may
# contain are decided here.
include "base";
include "meta";
include "milestone";
include "release";

# plan_due($owner; $threshold; $roadmap):
#   {tags: [tag names],
#    milestones: [open milestones {number, title, due_on, open_issues, closed_issues}],
#    issues: [open issues {number, title, body, author, labels, milestone}],
#    closed_plans: [closed issues {number, title, body, author}]   optional}
#   $roadmap: path of the roadmap file, "" when the repository has none
#   -> {due, reason, version, title, existing, active, facts}
# Due when the active milestone (lib/milestone.jq) has $threshold or fewer open issues
# and the owner has no "Plan vX.Y" issue, open or closed, for the next minor version
# after the latest vX.Y.Z tag. Off when there is no open milestone or no such tag.
# facts is what the model is shown: numbers, titles and labels of the OWNER's issues only.
def plan_due($owner; $threshold; $roadmap):
  def off($why): {due: false, reason: $why, version: null, title: null, existing: null, active: null, facts: null};
  def brief: {number, title, labels: [.labels[]?.name]};
  def has($l): [.labels[]?.name] | index($l) != null;
  (.tags | latest_tag) as $tag
  | (.milestones | active_milestone) as $active
  | if $active == null then off("no open milestone")
    elif $tag == null then off("no vX.Y.Z tag yet, so there is no next version to plan")
    elif ($active.open_issues // 0) > $threshold then
      off("milestone \($active.title | safe_line(80)) still has \($active.open_issues) open issues (planning starts at \($threshold) or fewer)")
    else
      ($tag | next_minor) as $version
      | "Plan \($version)" as $title
      # A Plan issue the loop filed: exact title, the owner as author AND the marker
      # plan_body puts in the body. A title alone is not enough: split children and
      # found issues are filed under the owner's name with model-written titles.
      | ([(.issues[], (.closed_plans // [])[])
          | select(.title == $title and .author.login == $owner and ((.body // "") | contains("<!-- agent-plan -->")))
          | .number] | sort | .[0]) as $existing
      | if $existing != null then
          off("#\($existing) \($title) already exists") | .existing = $existing | .version = $version | .title = $title
        else
          [.issues[] | select(.author.login == $owner) | select(is_meta_issue | not)] as $mine
          | {due: true,
             reason: "milestone \($active.title | safe_line(80)) has \($active.open_issues // 0) open issue(s) and there is no \($title) issue",
             version: $version, title: $title, existing: null,
             active: {number: $active.number, title: $active.title, open_issues: ($active.open_issues // 0)},
             facts: {
               version: $version,
               roadmap: (if $roadmap == "" then null else $roadmap end),
               active_milestone: {
                 title: $active.title, open_issue_count: ($active.open_issues // 0),
                 open_issues: [$mine[] | select(.milestone != null and .milestone.number == $active.number) | brief]},
               unmilestoned: ([$mine[] | select(.milestone == null) | brief] | .[:100]),
               stretch: ([$mine[] | select(has("stretch")) | select(.milestone == null or .milestone.number != $active.number) | brief] | .[:50])
             }}
        end
    end;

# plan_body($plan): the model's planning proposal (schemas/backlog-plan.json, .planning)
#   -> Markdown body of the Plan issue. $plan is the plan_due result that asked for it.
# Model text is reduced to single lines (safe_line) and the whole body goes through
# defang_base. An item may only name an issue that was offered in $plan.facts for that
# section; titles come from the facts, not from the model. Others are dropped and counted.
def plan_body($plan):
  def text($k): (.[$k] // "") | if type == "string" then safe_line(400) else "" end;
  def detail: "size: " + (text("size") | if . == "" then "not estimated" else . end)
              + ". Recommendation: " + (text("recommendation") | if . == "" then "none given" else . end);
  def items($pool; $max):
    [(. // [])[] | select(type == "object") | . as $it
      | ([$pool[] | select(.number == $it.issue)] | .[0]) as $f
      | select($f != null)
      | {n: $f.number, line: "- #\($f.number) \($f.title | safe_line(120)): \($it | detail)"}]
    | unique_by(.n) | .[:$max] | map(.line);
  def offered($pool): [(. // [])[] | select(type == "object") | .issue as $n | select([$pool[] | .number] | index($n) != null)] | length;
  def section($title; $lines; $none): ["## \($title)", ""] + (if ($lines | length) > 0 then $lines else [$none] end) + [""];
  . as $p
  | $plan.facts as $f
  | ($plan.active.title | safe_line(80)) as $ms
  | ([($p.features // []), ($p.stretch // []), ($p.move_out // [])] | map(length) | add) as $asked
  | ((($p.features // []) | offered($f.unmilestoned)) + (($p.stretch // []) | offered($f.stretch))
     + (($p.move_out // []) | offered($f.active_milestone.open_issues))) as $kept
  | ( [ "<!-- agent-plan -->",
        "Milestone **\($ms)** has \($plan.active.open_issues) open issue(s) left, so here is a proposal for \($plan.version). Nothing has been changed: no milestone was created or assigned and no label was touched. Answer in a comment; you make the changes.",
        "",
        ($p | text("summary")),
        "" ]
      + section("Next roadmap epic";
          (if $f.roadmap == null then []
           elif ($p.epic | type) == "object" then ["- **\($p.epic | text("title"))**: \($p.epic | detail)"]
           else [] end);
          (if $f.roadmap == null then "No roadmap file was found in this repository, so no epic is proposed."
           else "No epic proposed from `\($f.roadmap)`." end))
      + section("Unmilestoned features (up to 5)"; ($p.features | items($f.unmilestoned; 5)); "None proposed.")
      + section("Stretch issues worth promoting"; ($p.stretch | items($f.stretch; 20)); "None proposed.")
      + section("Move out of \($ms)"; ($p.move_out | items($f.active_milestone.open_issues; 20)); "Nothing proposed.")
      + (if $asked > $kept then ["(\($asked - $kept) proposed item(s) named an issue that was not offered for that section and were dropped.)"] else [] end)
    ) | join("\n") | defang_base;
