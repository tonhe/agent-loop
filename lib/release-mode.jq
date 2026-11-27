# Release mode or maintenance mode (#61). One rule, shared by triage (validate-plan.jq,
# through apply-backlog.sh), dev selection (select.jq) and a sprint (sprint-select.sh).
#
# A milestone is approved for release when its description has the line
#     agent-loop: release
# on its own (case and the spaces around it do not matter). The owner adds it when the
# release is planned; closing the milestone ends it. The loop never writes milestones.
# With an approved open milestone the repository is in release mode, without one in
# maintenance mode.
#
# The only type that is gated: a type:feature issue may be agent:ready, and may be
# picked, only when it is in an approved milestone. type:bug, type:enhancement (it
# ships in a patch), type:test, type:docs, type:chore, type:refactor and tech-debt are
# allowed in both modes, in any milestone or none.

# release_approved: milestone {description} -> bool
def release_approved:
  (.description // "") | if type == "string" then . else "" end
  | split("\n") | any(.[]; sub("\r\\z"; "") | test("\\A[ \\t]*agent-loop:[ \\t]*release[ \\t]*\\z"; "i"));

# approved_milestones: [open milestones {number, description}] -> [numbers]
def approved_milestones: [.[] | select(release_approved) | .number];

# release_mode: [open milestones {number, title, description}]
#   -> {mode: "release" | "maintenance", approved: [{number, title}]}
def release_mode:
  [.[] | select(release_approved) | {number, title}] as $a
  | {mode: (if ($a | length) > 0 then "release" else "maintenance" end), approved: $a};

# is_feature: issue {labels: [{name}] or [names]} -> bool
def is_feature:
  [(.labels // [])[] | if type == "object" then .name else . end] | index("type:feature") != null;

# in_approved($approved): issue {milestone: {number} | null} -> bool
def in_approved($approved):
  (.milestone.number? // null) as $m | $m != null and ($approved | index($m)) != null;

# ready_allowed($approved): issue -> bool : may this issue be agent:ready / be picked?
def ready_allowed($approved): (is_feature | not) or in_approved($approved);

# type_prefix: [label names] -> the conventional-commit prefix of the issue's type, or
# null for a type:feature issue or one without a type label. The first type label that
# matches, in this order, wins.
def type_prefix:
  . as $l
  | if ($l | index("type:feature")) != null then null
    else [["type:enhancement", "enhance"], ["type:bug", "fix"], ["type:docs", "docs"], ["type:test", "test"],
          ["type:refactor", "refactor"], ["type:chore", "chore"]]
         | map(select(.[0] as $t | $l | index($t) != null) | .[1]) | .[0]
    end;

# no_feat_prefix($labels): a commit subject or PR title -> the same, except that a
# leading "feat" (feat:, feat(scope):, feat!:) on an issue that is not type:feature
# becomes the issue type's prefix: a feat makes the next release a minor one, and only
# a feature may do that. Scope and "!" are kept. Without a type label nothing changes.
def no_feat_prefix($labels):
  ($labels | type_prefix) as $p
  | if $p != null and test("\\Afeat(\\([^)]*\\))?!?:"; "i") then $p + .[4:] else . end;
