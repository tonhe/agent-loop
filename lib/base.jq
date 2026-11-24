# Per-issue base branch: which branch the dev agent checks out, branches from and
# opens its PR against.
#
# An issue names its base with a body line   Base: <branch>   (optionally in backticks,
# on a line of its own) or with a label      base:<branch>
# The body line wins when both are present. Anything that is not a plain branch name is
# an error, never a silent fall-back: the value ends up in git and gh commands.

# valid_ref: string -> true for a plain branch name: letters, digits, . _ - / only,
# starting with a letter or digit, at most 100 characters, no "..", no "//", no path
# component starting with "." or ending in ".lock", no trailing "/" or ".", not HEAD,
# not a full "refs/..." name. \A and \z, not ^ and $: those match at every line.
def valid_ref:
  type == "string"
  and test("\\A[A-Za-z0-9][A-Za-z0-9._/-]{0,99}\\z")
  and (test("\\.\\.|//|/\\.|\\.lock(/|\\z)|[./]\\z|\\AHEAD\\z|\\Arefs/") | not);

# body_bases: issue body -> the value of every "Base:" line, trimmed.
def body_bases:
  (. // "") | split("\n")
  | map(sub("\r\\z"; "")
        | select(test("\\A[ \\t]*Base:"))
        | sub("\\A[ \\t]*Base:[ \\t]*"; "") | sub("[ \\t]+\\z"; "")
        | (capture("\\A`(?<b>[^`]*)`\\z").b // .));

# label_bases: issue -> the value of every base:<branch> label.
def label_bases: [.labels[]?.name | select(startswith("base:")) | ltrimstr("base:")];

# agent_branch: string -> true for a branch the dev agent pushes its own work to
# (publish-pr.sh names them issue-N). Those hold unreviewed, agent-written code, so they
# are never accepted as a base: the next run would check that code out and build on it.
def agent_branch: test("\\Aissue-[0-9]+\\z");

# defang_base: text -> the same text with every "Base:" line rewritten so it no longer
# parses as one. Applied to bodies the model wrote before they are filed as issues
# (found issues, split children): an issue body is otherwise the owner's own words, and
# a Base: line in it is an instruction about which code to check out.
def defang_base:
  split("\n") | map(sub("\\A(?<i>[ \\t]*)Base:"; "\(.i)Suggested base (not applied):")) | join("\n");

# resolve_base: issue {body, labels: [{name}]} ->
#   {"base": "<branch>" | null, "source": "body" | "label" | null, "error": null | "<why>"}
# base null with error null means the issue asks for nothing: use the default base.
def resolve_base:
  def bad($where): {base: null, source: null,
    error: ("the base branch named in " + $where + " is not a plain branch name (letters, digits, `.`, `_`, `-` and `/` only).")};
  def pick($value; $source; $where):
    if ($value | valid_ref | not) then bad($where)
    elif ($value | agent_branch) then {base: null, source: null,
      error: ("the base branch named in " + $where + " is one the dev agent created. A base must be a branch you pushed.")}
    else {base: $value, source: $source, error: null} end;
  (.body | body_bases | unique) as $b
  | (label_bases | unique) as $l
  | ([.labels[]?.name] | index("agent:found") != null) as $found
  | if ($b | length) > 1 then
      {base: null, source: null, error: "the issue body has more than one `Base:` line and they disagree."}
    elif ($b | length) == 1 and $found then
      # file-found.sh files these as the owner, but the model wrote the body.
      {base: null, source: null,
       error: "this issue was filed by the dev agent, so a `Base:` line in its body is not trusted. Remove the line and add a `base:<branch>` label instead."}
    elif ($b | length) == 1 then
      pick($b[0]; "body"; "the issue body's `Base:` line")
    elif ($l | length) > 1 then
      {base: null, source: null, error: "the issue has more than one `base:` label."}
    elif ($l | length) == 1 then
      pick($l[0]; "label"; "the `base:` label")
    else
      {base: null, source: null, error: null}
    end;
