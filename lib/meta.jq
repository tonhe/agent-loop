# Issues the loop files for the owner to decide on: "Release vX.Y.Z" (release-issue.sh)
# and "Plan vX.Y" (apply-backlog.sh). Their bodies are built from commit messages or
# written by the model, so they are not the owner's words. They are never triaged and
# never worked by the dev agent.
#
# is_meta_issue: issue {body} -> true when the body carries the marker those scripts
# put on the first line.
def is_meta_issue: (.body // "") | test("<!-- agent-(release|plan) -->");

# The other issues the loop files as the owner have a title and a body the model wrote:
# split children (apply-backlog.sh) and found issues (file-found.sh). Neither may pass
# for a Release or Plan issue, by title or by marker.
#
# safe_title: model-written title -> one line, trimmed, and never beginning with
# "Release v<digit>" or "Plan v<digit>" (any case, any spacing): those get "Re: " in
# front, so the exact titles release.jq and planning.jq look for cannot be produced.
def safe_title:
  tostring
  | explode | map(if . < 32 or . == 127 then 32 else . end) | implode
  | sub("\\A\\s+"; "") | sub("\\s+\\z"; "")
  | if test("\\A(Release|Plan)\\s+v[0-9]"; "i") then "Re: " + . else . end;

# defang_markers: model-written body -> the same text in which no HTML comment can
# open, so no "<!-- agent-..." marker can be forged (the same rewrite as safe_line in
# lib/release.jq). The scripts add their own markers after this.
def defang_markers: gsub("<!--"; "&lt;!--");
