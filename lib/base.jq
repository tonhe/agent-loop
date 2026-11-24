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

# resolve_base: issue {body, labels: [{name}]} ->
#   {"base": "<branch>" | null, "source": "body" | "label" | null, "error": null | "<why>"}
# base null with error null means the issue asks for nothing: use the default base.
def resolve_base:
  def bad($where): {base: null, source: null,
    error: ("the base branch named in " + $where + " is not a plain branch name (letters, digits, `.`, `_`, `-` and `/` only).")};
  (.body | body_bases | unique) as $b
  | (label_bases | unique) as $l
  | if ($b | length) > 1 then
      {base: null, source: null, error: "the issue body has more than one `Base:` line and they disagree."}
    elif ($b | length) == 1 then
      if $b[0] | valid_ref then {base: $b[0], source: "body", error: null} else bad("the issue body's `Base:` line") end
    elif ($l | length) > 1 then
      {base: null, source: null, error: "the issue has more than one `base:` label."}
    elif ($l | length) == 1 then
      if $l[0] | valid_ref then {base: $l[0], source: "label", error: null} else bad("the `base:` label") end
    else
      {base: null, source: null, error: null}
    end;
