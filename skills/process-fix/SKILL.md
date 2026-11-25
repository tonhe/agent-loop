---
name: process-fix
description: What to do when agent-loop's own process breaks during a sprint (a script bug, a wrong rule, a missing label, a gate that refuses wrongly) - file an issue in tonhe/agent-loop, optionally open a PR there, never merge it, never change a gate to get past it, and carry on with other work.
---

# process-fix

The loop's process is the owner's: the scripts and gates in agent-loop, the caller workflows, `CLAUDE.md`, `RELEASING.md`, labels and rulesets. When it gets in the way:

1. **Don't route around it.** Do not edit the installed plugin, the caller workflows or a ruleset, do not remove a label the process set, and do not write a comment in the owner's voice. The guard hook blocks most of these. The rest is on you.
2. **File it.** One issue in agent-loop, in plain words:
   `gh issue create -R tonhe/agent-loop --title "<what breaks>" --body-file F`
   F says what you ran (the exact command), what happened (the exact output), what you expected and why, and the repository and PR or issue URL where it happened. Search first (`gh issue list -R tonhe/agent-loop --search "<words>"`) and comment on an existing issue instead of filing a duplicate.
3. **Optionally, a PR.** Only if the fix is small and you are sure: work in a separate clone of tonhe/agent-loop (never the installed plugin directory), add a test to `test/run.sh` or `test/sprint.sh` that fails before the fix, run `bash test/run.sh`, and open a PR that names the issue URL. Never merge it, and never ask the merge gate to: it refuses agent-loop by design, and the owner reviews process changes.
4. **Carry on.** Leave the affected issue or PR for the owner, list the process issue URL in the sprint's final report under "process issues filed", and go on with other work. Never wait for the fix.
