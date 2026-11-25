---
name: merge-gate
description: The only way a sprint merges an agent PR - run agent-loop's merge-gate.sh, which checks every rule (required checks green, no protected or process paths, Owner decision where needed, live check answered, issue not needs:human, mergeable) and only then turns on auto-merge. Use whenever a sprint or the owner wants an agent PR merged.
argument-hint: PR_NUMBER
---

# merge-gate

`bash ${CLAUDE_PLUGIN_ROOT}/scripts/merge-gate.sh PR` is the only merge path. Nothing else merges: `gh pr merge`, the merge API and `enable-automerge.sh` are blocked by the plugin's guard hook, and the repository ruleset still requires the checks.

- Exit 0: every rule holds and auto-merge is on. GitHub merges once the required checks pass. Count the PR as merged only when `gh pr view PR --json state` says `MERGED`.
- Exit 1: refused. It prints one line per reason. Leave the PR for the owner, except in the cases below.
- `--check` decides and prints without turning anything on.

What to do with a refusal:

| Reason | Do |
|---|---|
| required check pending / not reported | Wait and run the gate again later (go on with other work first). Never re-run or cancel checks to hurry them. |
| head is behind the base (strict ruleset) | `gh pr update-branch PR` once, then wait for the checks again. |
| a required check failed | Not yours to fix here. The follow-up workflow runs one fix round, or the owner decides. Report it. |
| protected path, process path, needs:human, no Owner decision, live check missing or failed, conflicts, fork, not a loop PR, agent-loop itself | Leave it for the owner. List it in the sprint's final report with the reason. |

Never change anything to get past a reason: no edits to the gate, its config (caller workflows), labels, rulesets or comments in the owner's voice. If the gate itself looks wrong, use the `process-fix` skill and move on.
