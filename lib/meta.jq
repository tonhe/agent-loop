# Issues the loop files for the owner to decide on: "Release vX.Y.Z" (release-issue.sh)
# and "Plan vX.Y" (apply-backlog.sh). Their bodies are built from commit messages or
# written by the model, so they are not the owner's words. They are never triaged and
# never worked by the dev agent.
#
# is_meta_issue: issue {body} -> true when the body carries the marker those scripts
# put on the first line.
def is_meta_issue: (.body // "") | test("<!-- agent-(release|plan) -->");
