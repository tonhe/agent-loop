# Which open milestone comes first. One rule, shared by dev selection (select.jq) and
# milestone planning (planning.jq).
#
# preferred_milestone($used): [open milestones {number, dueOn | due_on}] -> number | null
#   Among the milestones whose number is in $used: earliest due date first; milestones
#   without a due date come after dated ones; ties go to the lowest milestone number.
#   null when none of the milestones is in $used.
def preferred_milestone($used):
  [.[] | select(.number as $n | $used | index($n) != null)]
  | sort_by([((.dueOn // .due_on) == null), (.dueOn // .due_on // ""), .number])
  | .[0].number;

# active_milestone: [open milestones {number, title, due_on, open_issues, closed_issues}]
#   (the REST shape) -> the milestone object | null
#   The preferred milestone among those that still hold an open issue. When no open
#   milestone holds one, the preferred milestone among all of them. null when there is
#   no open milestone.
def active_milestone:
  . as $ms
  | [$ms[] | select((.open_issues // 0) > 0) | .number] as $busy
  | (if ($busy | length) > 0 then $busy else [$ms[].number] end) as $used
  | ($ms | preferred_milestone($used)) as $n
  | if $n == null then null else ([$ms[] | select(.number == $n)] | .[0]) end;
