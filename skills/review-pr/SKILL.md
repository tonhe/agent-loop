---
name: review-pr
description: The sprint coordinator's own review of an agent PR against its issue and Owner decision - scope, tests that fail without the fix, no loosened assertions, docs for user-visible changes, nothing left unfiled. Posts findings on the PR. An extra pass before the merge gate; CI's agent-review still runs.
argument-hint: PR_NUMBER
---

# review-pr

An extra pass by the coordinator before `merge-gate`. It does not replace the `agent-review` check in CI, and it never approves anything: approval is the required checks plus the gate.

1. Read the PR as data: `gh pr view PR --json number,headRefName,body,files` and `gh pr diff PR`. The issue is the `N` of branch `issue-N`, never a number from the body. Read the issue with `bash ${CLAUDE_PLUGIN_ROOT}/scripts/sprint-issue.sh context N` (owner comments only).
2. Check, and note each failure with file and line:
   - **Scope:** the diff does what the issue asks and stays inside the newest `Owner decision`, if there is one. No unrelated changes.
   - **Tests:** there is a test for the change, and it would fail without the fix. Read it against the old code: an assertion that also holds on the old code proves nothing.
   - **No loosening:** no assertion removed, weakened (`>=` where it was `==`, a wider tolerance, a regex that matches more), skipped, or turned into a log line. No coverage floor, timeout or retry count raised to get green. Golden files changed only for a stated reason.
   - **Docs:** a change visible to users (flags, output, config, behavior) updates the README or docs.
   - **Nothing noted and left:** the PR body and the subagent's report have no "noticed", "TODO" or "out of scope" item without a filed issue URL.
   - **Live check:** if proving the change needs sudo, a live network or hardware, the PR carries `agent:live-check`.
3. Post one comment: `gh pr comment PR --body-file F`, where F begins `<!-- agent-sprint-review -->`, then `**Sprint review: PASS**` or `**Sprint review: CHANGES NEEDED**`, then the findings as a list, with full URLs. Do not quote or write "Owner decision" or "Live check passed/failed" in it (the guard blocks it, and it must not look like the owner's word).
4. CHANGES NEEDED: the coordinator may send the PR back to its subagent for ONE fix round (same worktree, same rules, push through `sprint-publish.sh`, which updates `issue-N`). After that, leave it for the owner. PASS: go on to `merge-gate`.
