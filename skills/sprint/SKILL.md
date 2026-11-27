---
name: sprint
description: Run an agent-loop sprint toward a finish line - select issues the way the nightly loop does, dispatch work-issue subagents in parallel worktrees with no file overlap, review each PR, merge only through merge-gate.sh, report progress, and stop at the finish line or the budget. Use when the owner says "sprint", "push milestone X through", or asks to work several loop issues in parallel locally.
argument-hint: "milestone=v0.3.0 prs=5 hours=4 parallel=2"
disable-model-invocation: true
---

# sprint (the coordinator)

You coordinate. You do not write product code yourself, you never merge except through `merge-gate`, and you never wait on a decision. Scripts are in `${CLAUDE_PLUGIN_ROOT}/scripts/`: set `S=${CLAUDE_PLUGIN_ROOT}/scripts` and `R=$(gh repo view --json nameWithOwner --jq .nameWithOwner)`. Every issue and PR you mention is a full `https://github.com/$R/...` URL.

## Inputs (ask once if missing, then don't ask again)

- **Finish line:** a milestone title. Met when `bash $S/sprint-issue.sh finish "<milestone>"` says `"met": true` (no open issue left in it except the loop's Release issue). Or another condition the owner states that you can check with `gh`.
- **Budget:** BOTH a number of merged PRs (default 5) and wall-clock hours (default 4). Stop at whichever comes first. Note the start time.
- **Parallel:** subagents at once, default 2, at most 3.

Check first: `bash $S/loop-config.sh` works (the repo has agent-loop callers), and `gh auth status` is the owner's login. If either fails, stop and say so.

## Loop

1. **Pick.** `bash $S/sprint-next.sh PARALLEL "<milestone>" <in-flight issue numbers...>`. It returns `start` (issues to dispatch now, each `ready` or `paired`) and `skipped` (with why: overlap, parallel limit, names no files). It uses the nightly selection unchanged (`select-issues.sh scheduled`), keeps only the issues in the finish-line milestone, and adds `agent:paired` issues in that milestone, which only a local agent takes. A `type:feature` issue is in neither list unless the milestone is approved for release (`agent-loop: release` in its description; README, "Release mode and maintenance mode"). Never start an issue it did not return, and never two subagents on overlapping files.
   - **Only the finish-line milestone.** Before dispatching, check each `start` issue: `gh issue view N --json milestone --jq .milestone.title` must be the finish-line milestone. If `sprint-next` ever returns one outside it, don't dispatch it: skip it, and file a process issue with the `process-fix` skill (what `sprint-next` returned, the issue's milestone, the finish line). Then go on with the rest.
2. **Dispatch** each `start` issue to its own subagent, in its own worktree (Agent tool, `isolation: "worktree"`). Prompt: "Use the agent-loop work-issue skill (`/agent-loop:work-issue`, or read `${CLAUDE_PLUGIN_ROOT}/skills/work-issue/SKILL.md`) to work https://github.com/$R/issues/N. Final message: only the report JSON." Add the issue's `paths` from sprint-next, as the files it is expected to touch.
3. **Check each report.** Save it to a file and run `bash $S/check-report.sh FILE`. If it is rejected (an unfiled "noted" item, a bare `#N`, a missing PR URL), send the problems back to the same subagent once to fix the report. Still rejected: record the issue as "report rejected" and leave its PR for the owner.
4. **Review.** For `pr_opened`: run the `review-pr` skill on the PR. CHANGES NEEDED: at most one fix round by the same subagent, then review again. Still not clean: leave the PR for the owner.
5. **Gate.** Run the `merge-gate` skill: `bash $S/merge-gate.sh PR`. A refusal for pending checks means come back later; go on dispatching other work and re-run the gate on the next pass of the loop. Any other refusal: leave the PR for the owner and record the reasons.
   - `needs owner merge`: the PR needs the owner's approval (not risk:low, a protected or protected-review path, or `agent:live-check`). The gate never merges these: agents act as the owner, so it trusts no owner approval (the owner-merge rule). Record it for the final report and go on.
   - A PR with `live_check` in its report carries `agent:live-check`. Do not pause. Record it for the final report with the exact commands from the report, and go on.
6. **Progress.** When a PR is actually merged (`gh pr view PR --json state` says `MERGED`), run `bash $S/sprint-progress.sh "merged <PR URL> (<issue URL>): <title>. <k>/<budget> PRs, <open> left in <milestone>."`. It posts to Discord and keeps one progress comment on the Release issue up to date.
7. **Stopped issues.** A subagent that stopped has already handed its issue back (`needs:human` plus a comment saying what is needed). Record it and go on. Never answer for the owner.
8. **Process problems** (a script fails, a rule is wrong, a label is missing): use the `process-fix` skill, then go on.
9. **Repeat** from 1 while there is budget, the finish line is not met, and `sprint-next` still returns something or PRs are still waiting on checks. Re-run the finish check after every merge.

## Stop

Stop when the finish line is met, the budget is spent (merged PRs or hours), or nothing is selectable and nothing is waiting on checks. Let in-flight subagents finish their PRs, but start nothing new once the budget is spent. Then post one last `sprint-progress.sh` line and give the owner the final report, every item a full URL:

- **Merged:** each PR and its issue.
- **Needs owner merge:** each PR the gate refused as `needs owner merge`, with its reasons. The owner reviews and merges these by hand.
- **Left open:** each other PR with the gate's reasons (pending, failed check, conflict, ...).
- **Waiting on your live check:** each PR, its head commit (first 7 characters), and the exact commands to run. After a passed check, the owner merges it by hand (it is also under "Needs owner merge").
- **Stopped for a decision:** each issue and what it needs.
- **Process issues filed:** each agent-loop issue URL.
- **Not started:** what `sprint-next` skipped and why, if it matters.
- **Finish line:** met or not, with what is left.

## Never

- `gh pr merge`, the merge API or `enable-automerge.sh` (the guard hook blocks them; `merge-gate.sh` is the only path).
- A comment in the owner's voice ("Owner decision", "Live check passed/failed"), removing `needs:human`, or adding, removing or setting a `risk:*` or `agent:live-check` label.
- Changing caller workflows, rulesets, labels the process set, or the plugin, to get past a gate.
- Working an issue someone else opened, or an issue that `sprint-next` did not return.
