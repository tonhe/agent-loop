# Which issue does a pull request belong to?
#
# One rule, used by the review gate (scripts/review-gate.sh), the follow-up job
# (lib/followup.jq, followup.yml) and selection (lib/select.jq):
#
#   The issue number is the N of the head branch name issue-N, which publish-pr.sh sets.
#   It is never taken from the PR body: the body starts with text the model wrote. The
#   marker publish-pr.sh appends to the body (<!-- agent-loop issue=N -->) can only agree
#   with the branch or not.
#
# Input everywhere: a PR object {"headRefName": "...", "body": "..."} (gh's field names).
# Missing or null fields are read as "no branch" and "empty body".

# issue_head: PR -> true when the head branch has the shape of an agent branch, digits of
# any kind (issue-036 and issue-0 included). Same shape as agent_branch in lib/base.jq.
# \A and \z, not ^ and $: those match at every line.
def issue_head: (.headRefName // "") | (type == "string" and test("\\Aissue-[0-9]+\\z"));

# branch_issue: PR -> N for head branch issue-N, else null. N is a plain positive number:
# no leading zeros, not 0, at most 9 digits.
def branch_issue:
  (.headRefName // "")
  | if type == "string" and test("\\Aissue-[1-9][0-9]{0,8}\\z") then ltrimstr("issue-") | tonumber else null end;

# body_markers: PR -> every distinct number an "agent-loop issue=N" marker in the body
# names, as strings (so an absurd number is compared as text, never rounded).
def body_markers: [(.body // "") | strings | scan("agent-loop issue=([0-9]+)")[]] | unique;

# pr_issue: PR -> N when the head branch is issue-N AND the body carries the marker and
# every marker names N; else null. This is "a loop PR in good order".
def pr_issue: branch_issue as $n | if $n != null and body_markers == [$n | tostring] then $n else null end;

# pr_link: PR -> everything a caller needs to tell the cases apart:
#   {"issue_head": bool, "issue": N|null (branch_issue), "markers": bool, "agrees": bool}
def pr_link: {issue_head: issue_head, issue: branch_issue, markers: (body_markers | length > 0), agrees: (pr_issue != null)};
