# The merge gate's decision: may a local agent turn on auto-merge for this PR?
#
# scripts/merge-gate.sh gathers the facts from GitHub and git; this file only decides,
# so every refusal can be tested offline. The gate is the only way the sprint skills
# merge anything (see skills/merge-gate), and it never merges by itself: on success the
# script calls enable-automerge.sh, and GitHub still merges only when the ruleset allows.
#
# Input (all fields required unless marked optional):
# {
#   "owner":  "tonhe",                     owner_login, from the caller workflows on the base
#   "is_loop_repo": false,                 true when the PR is in agent-loop itself
#   "pr": {number, state, isDraft, isCrossRepository, author: {login}, headRefName,
#          headRefOid, baseRefName, body, mergeable ("MERGEABLE"|"CONFLICTING"|"UNKNOWN"),
#          labels: [{name}], comments: [{author: {login}, body}]},
#   "issue": {number, state, author: {login}, body, labels: [{name}], comments: [...]} | null,
#   "files": ["path", ...],                every path the PR touches, both sides of a rename
#   "files_complete": true,                false when GitHub listed fewer files than changed
#   "protected_hits": ["path", ...],       files matching protected_paths (git pathspecs,
#                                          the same test as check-diff.sh), worked out by
#                                          the script with git itself
#   "protected_review_paths": "text",      the review caller's input, one glob per line
#   "rules": [...],                        GET repos/{repo}/rules/branches/{base}
#   "checks": [{name, status, conclusion}],  check runs on the head commit, newest first
#   "statuses": [{context, state}],        commit statuses on the head commit, newest first
#   "behind_by": 0,                        commits on the base that the head lacks
#   "label_events": [{event, created_at, label}],  labeled/unlabeled events of the issue
#                                          (its timeline, oldest first); pr.createdAt is
#                                          when the PR opened
#   "pr_label_events": [{event, created_at, label}],  the same for the PR
#   "owner_approvals_trusted": false       optional, default false: see owner_merge_url.
#                                          merge-gate.sh writes the literal false; no env
#                                          var, config or argument reaches it
# }
#
# Output: {"ok": bool, "issue": N|null, "reasons": ["...", ...]}. ok only when reasons
# is empty. Every rule adds its own reason, so the owner sees all of them at once.

include "pr";
include "glob";
include "meta";

# Paths that make up the loop's own process. A PR touching any of them is the owner's to
# merge, never an agent's: workflows and their config (the caller workflows hold the
# agent-loop inputs), agent instructions and settings, and the release procedure.
def process_patterns:
  [".github", ".claude", ".claude-plugin", ".mcp.json", "**/CLAUDE.md", "**/CLAUDE.local.md",
   "**/AGENTS.md", "RELEASING.md"];

# required_contexts: rules -> [names of required checks], from every required_status_checks
# rule that applies to the branch (there may be several rulesets).
def required_contexts:
  [.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]?.context] | unique;

# strict_up_to_date: rules -> true when any rule asks for the branch to be up to date.
def strict_up_to_date:
  any(.[]; .type == "required_status_checks" and (.parameters.strict_required_status_checks_policy == true));

# check_state($checks; $statuses): context name -> "success" | "pending" | "skipped" |
# "failed: <conclusion>". The newest check run with that exact name counts (a re-run
# replaces the earlier one); otherwise the newest commit status with that context.
# Missing altogether is pending: it has not reported yet.
def check_state($checks; $statuses):
  . as $name
  | ([$checks[] | select(.name == $name)] | .[0]) as $run
  | ([$statuses[] | select(.context == $name)] | .[0]) as $st
  | if $run != null then
      if $run.status != "completed" then "pending"
      elif $run.conclusion == "success" then "success"
      elif $run.conclusion == "skipped" or $run.conclusion == "neutral" then "skipped"
      else "failed: \($run.conclusion // "unknown")" end
    elif $st != null then
      if $st.state == "success" then "success"
      elif $st.state == "pending" then "pending"
      else "failed: \($st.state)" end
    else "pending" end;

# Live check: a PR labeled agent:live-check waits for the owner to run something only a
# person can (sudo, a live network). The owner answers with a PR comment that begins
# "Live check passed" or "Live check failed" and names the head commit (at least its
# first 7 characters). A push after the answer makes it stale. The newest answer for the
# current head counts (input comments are oldest first, as gh returns them). Comments
# carrying a loop marker never count.
def live_answer_re: "\\A[ \\t\\r\\n#*_>]*Live check (passed|failed)";
def live_answers($owner; $sha):
  [.[] | select(.author.login == $owner) | (.body // "")
       | select(contains("<!-- agent-") | not)
       | select(test(live_answer_re))
       | select([scan("\\b[0-9a-f]{7,40}\\b")] | any(. as $s | $sha | startswith($s)))
       | if test("\\A[ \\t\\r\\n#*_>]*Live check passed") then "passed" else "failed" end];

def labels_of: [(.labels // [])[].name];

# Interim rule, until https://github.com/tonhe/agent-loop/issues/35 is done: agents act
# as the owner on GitHub (the owner's gh login), so an "Owner decision" or "Live check
# passed" comment by owner_login may have been written by an agent. Until agents have
# their own identity, the gate trusts no owner approval and enables auto-merge only for
# PRs that need none: issue risk:low, no protected_paths or protected_review_paths file,
# no agent:live-check. Every other PR is refused with "needs owner merge" and left for
# the owner. merge-gate.sh sets owner_approvals_trusted to false literally; the field
# exists so the approval rules below stay tested for when #35 lands.
def owner_merge_url: "https://github.com/tonhe/agent-loop/issues/35";

def merge_gate:
  . as $in
  | ($in.pr // {}) as $pr
  | ($pr | branch_issue) as $n
  | ($pr | pr_issue) as $agreed
  | ($in.issue) as $iss
  | ($in.rules // []) as $rules
  | ($rules | required_contexts) as $required
  | ($in.owner_approvals_trusted == true) as $trusted
  | [
      # --- the PR is a loop PR in good order ---
      (if $in.is_loop_repo == true then
         "this PR is in agent-loop itself: a change to the loop's own process is merged by the owner, never through the gate" else empty end),
      (if $pr.state != "OPEN" then "PR is not open (state \($pr.state // "unknown"))" else empty end),
      (if $pr.isDraft == true then "PR is a draft" else empty end),
      (if $pr.isCrossRepository != false then "PR comes from a fork" else empty end),
      (if ($pr.author.login // "") != $in.owner then "PR was opened by \($pr.author.login // "unknown"), not \($in.owner)" else empty end),
      (if $n == null then "head branch \($pr.headRefName // "?" | tojson) is not issue-N: only PRs opened by publish-pr.sh go through the gate"
       elif $agreed == null then "the body marker does not agree with branch issue-\($n) (missing, or names another issue)"
       else empty end),
      (if ($pr.headRefOid // "" | test("\\A[0-9a-f]{40}\\z") | not) then "head commit is unknown" else empty end),

      # --- the linked issue ---
      (if $n == null then empty
       elif $iss == null then "issue #\($n) could not be read"
       elif ($iss.number != $n) then "issue read (#\($iss.number)) is not the branch's issue #\($n)"
       else
         (if $iss.state != "OPEN" then "issue #\($n) is not open" else empty end),
         (if ($iss.author.login // "") != $in.owner then "issue #\($n) was opened by \($iss.author.login // "unknown"), not \($in.owner)" else empty end),
         (if ($iss | is_meta_issue) then "issue #\($n) is a Release or Plan issue" else empty end),
         (if ($iss | labels_of | index("needs:human")) != null then "issue #\($n) is labeled needs:human" else empty end)
       end),

      # --- required checks on the head commit ---
      (if ($required | length) == 0 then "base branch \($pr.baseRefName // "?") has no required status checks" else empty end),
      ($required[] as $c | ($c | check_state($in.checks // []; $in.statuses // [])) as $s
        | if $s == "success" then empty
          elif $s == "pending" then "required check \($c | tojson) has not finished (pending or not reported)"
          elif $s == "skipped" then "required check \($c | tojson) was skipped or neutral, not passed"
          else "required check \($c | tojson) \($s)" end),

      # --- protected and process paths ---
      (if $in.files_complete != true then "the PR's file list is incomplete (GitHub lists at most 3000 files), so protected paths cannot be checked" else empty end),
      ($in.protected_hits // [] | .[] | "needs owner merge: changes protected path \(tojson) (protected_paths: the agent may not change it)"),
      ($in.files // [] | .[] | . as $f | ($f | glob_hit(process_patterns)) as $g | select($g != null)
        | "changes the loop's process: \($f | tojson) (\($g))"),
      (if $iss == null or $n == null then empty
       else ({files: ($in.files // []), comments: ($iss.comments // [])}
             | review_protected($in.protected_review_paths // ""; $in.owner)) as $rp
         | if ($trusted | not) then
             ($rp.matched[] | "needs owner merge: changes \(.file | tojson) (protected_review_paths \(.glob)); an Owner decision cannot be verified while agents act as the owner (\(owner_merge_url))")
           elif $rp.status == "no_decision" then
             ($rp.matched[] | "changes \(.file | tojson) (protected_review_paths \(.glob)) and issue #\($n) has no Owner decision comment")
           else empty end
       end),
      (if $trusted or $iss == null or $n == null or ($iss | type) != "object" then empty
       elif ($iss | labels_of | index("risk:low")) == null then
         "needs owner merge: issue #\($n) is not risk:low (\([$iss | labels_of | .[] | select(startswith("risk:"))] | if length == 0 then "no risk label" else join(", ") end)); only risk:low PRs are merged by the gate until \(owner_merge_url) is done"
       else empty end),

      # --- risk label history ---
      # The auto-merge rule trusts risk:low, and an agent acting as the owner could set it.
      # A risk:* label added or removed after the PR was opened leaves the PR for the owner.
      (if $n == null or ($iss | type) != "object" then empty
       elif ($in.label_events | type) != "array" then "needs owner merge: the label history of issue #\($n) could not be read"
       elif ($pr.createdAt // "" | test("\\A[0-9]{4}-")) | not then "needs owner merge: the PR's opening time is unknown, so issue #\($n)'s risk label history cannot be checked"
       else [$in.label_events[] | select((.label // "") | startswith("risk:")) | select((.created_at // "") >= $pr.createdAt)] as $ch
         | if ($ch | length) == 0 then empty
           else "needs owner merge: issue #\($n)'s risk label changed after the PR was opened (\([$ch[] | "\(.event) \(.label) at \(.created_at)"] | join(", ")))"
           end,
         # The history replayed must give the risk labels the issue has now. Events keep
         # the label's name at the time, so a label renamed since (risk:medium -> risk:low)
         # shows up here as a mismatch.
         (reduce ($in.label_events | sort_by(.created_at // "") | .[] | select((.label // "") | ascii_downcase | startswith("risk:"))) as $e
            ([]; ($e.label | ascii_downcase) as $l | if $e.event == "labeled" then (. + [$l] | unique) else map(select(. != $l)) end)) as $replayed
         | ([$iss | labels_of | .[] | ascii_downcase | select(startswith("risk:"))] | unique) as $now
         | if $replayed == $now then empty
           else "needs owner merge: issue #\($n)'s risk labels (\($now | join(", ") | if . == "" then "none" else . end)) do not match its label history (\($replayed | join(", ") | if . == "" then "none" else . end)): a label was renamed, or the history is incomplete"
           end
       end),

      # --- live check ---
      (if ($in.pr_label_events | type) != "array" then "needs owner merge: the PR's label history could not be read"
       elif ($pr | labels_of | index("agent:live-check")) != null then empty
       elif any($in.pr_label_events[]; (.label // "" | ascii_downcase) == "agent:live-check") then
         "needs owner merge: the PR was labeled agent:live-check and the label is gone: the owner runs the live check and merges"
       else empty end),
      (if ($pr | labels_of | index("agent:live-check")) == null then empty
       elif ($trusted | not) then
         "needs owner merge: labeled agent:live-check; the owner runs the live check and merges by hand, since a live-check answer cannot be verified while agents act as the owner (\(owner_merge_url))"
       else (($pr.comments // []) | live_answers($in.owner; $pr.headRefOid // "")) as $a
         | if ($a | length) == 0 then "labeled agent:live-check and the owner has not posted \"Live check passed\" for head \($pr.headRefOid // "" | .[0:7])"
           elif $a[-1] != "passed" then "the owner's live check for head \($pr.headRefOid // "" | .[0:7]) failed"
           else empty end
       end),

      # --- up to date and mergeable ---
      (if $pr.mergeable == "CONFLICTING" then "PR has merge conflicts with \($pr.baseRefName // "the base")" else empty end),
      (if ($rules | strict_up_to_date) and (($in.behind_by // 1) > 0) then
         "head is \($in.behind_by // "?") commit(s) behind \($pr.baseRefName // "the base") and the ruleset requires it to be up to date" else empty end)
    ] as $reasons
  | {ok: ($reasons | length == 0), issue: $n, reasons: $reasons};
