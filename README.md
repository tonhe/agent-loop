# agent-loop

Reusable GitHub Actions workflows that run Claude Code as an unattended issue-to-PR loop on public repos, with the guardrails enforced in scripts rather than prompts.

```
1:17 AM  backlog   triage the owner's issues -> labels, assessment, splits
2:17 AM  dev       up to 3 agent:ready issues, one job each -> PR as the owner
on PR    review    Claude review (required check) + CodeRabbit
after    followup  one fix round -> auto-merge if risk:low
always   digest    Discord message per run
```

Each project repo carries only four small caller workflows (`examples/caller/`). Everything else lives here, pinned by tag.

## Guardrails and where they are enforced

| Guardrail | Enforced by |
|---|---|
| Blocked issues wait: "Blocked by #N" (or "after #N merges") while #N is open, a blocker with no number, or an open blocker in GitHub's native issue dependencies keeps an issue out of triage and dev | `lib/blocked.jq`, `lib/native-blockers.jq`, `native-blockers.sh` |
| A per-issue base branch must be a plain branch name that already exists; anything else hands the issue back | `lib/base.jq`, `resolve-base.sh` |
| Only the owner's issues are ever shown to Claude | `select-issues.sh`, `issue-context.sh`, `lib/candidates.jq` (author check) |
| Other people's comments never reach Claude | `issue-context.sh`, `review-context.sh` (owner, CodeRabbit, github-actions only) |
| Backlog manager can't do anything directly | Read-only tools; returns JSON that `lib/validate-plan.jq` filters |
| `agent:ready` only for `risk:low`; human-set labels kept; `agent:urgent` untouchable | `lib/validate-plan.jq` |
| No network tools, no MCP, narrow Bash allowlist | `run-claude.sh` (`--tools`, `--allowedTools`, `--strict-mcp-config`, `--permission-mode dontAsk`) |
| Token limits | `--max-turns`, wall-clock `timeout`, job `timeout-minutes`, max issues per run, model per job |
| Agent can't touch CI, Makefile, coverage floors | `check-diff.sh` (`.github/` always, plus `protected_paths`); PAT lacks Workflows permission |
| "Done" means verified | Workflow re-runs `verify_command` itself in a step with no secrets |
| Agent code never runs next to the PAT | Verify step has no secrets; publish step applies a patch in a fresh checkout with hooks disabled |
| One fix round only | Marker comment posted before the round starts (`lib/followup.jq`) |
| Auto-merge can't skip checks | `enable-automerge.sh` refuses unless the PR's own base branch has required checks and an empty bypass list |
| Releases need a human | `environment: release` with you as required reviewer; PAT has no Deployments permission |
| Digest can't ping anyone | `discord.sh` sets `allowed_mentions.parse = []` |

## One-time setup (account level)

1. **Claude token.** On your machine: `claude setup-token`. Uses your subscription; runs share your usage limits.
2. **Fine-grained PAT** (Settings > Developer settings > Fine-grained tokens). Name it `agent-loop`, expiry 90 days, repository access: only the repos in the loop.
   - Contents: Read and write
   - Issues: Read and write
   - Pull requests: Read and write
   - Administration: Read-only (lets `enable-automerge.sh` verify the ruleset)
   - Metadata: Read-only (automatic)
   - Leave everything else off. Especially **Workflows**, **Deployments**, **Environments**, **Secrets**.
3. **This repo.** Push it to `tonhe/agent-loop` (public, so callers can use it), then `git tag v1 && git push --tags`. Callers pin `@v1`. Move the tag only on purpose.
4. **Discord.** Channel > Edit > Integrations > Webhooks > New webhook > copy URL.

## Per-repo setup

1. Copy `examples/caller/*.yml` to the repo's `.github/workflows/` and change the lines marked `CHANGE`.
2. Secrets (`gh secret set NAME -R owner/repo`, paste when prompted):
   - `CLAUDE_CODE_OAUTH_TOKEN`
   - `AGENT_PAT`
   - `DISCORD_WEBHOOK_URL` (optional)
3. Labels: `scripts/bootstrap-labels.sh owner/repo`
4. Settings > General > Pull Requests: enable **Allow squash merging** and **Allow auto-merge**; enable **Automatically delete head branches**.
5. Settings > Rules > Rulesets > New branch ruleset, target the default branch:
   - Enforcement: Active. **Bypass list: empty.**
   - Restrict deletions, Block force pushes
   - Require a pull request before merging, 0 approvals, allowed merge method: Squash
   - Require status checks to pass: every CI job that matters plus `review / agent-review`
   - Consequence: you also merge your own work through PRs. See "Direct pushes" below.
6. If the repo has a tag-triggered release workflow: Settings > Environments > New `release`, add yourself as required reviewer, and add `environment: release` to the release job.
7. Install the CodeRabbit GitHub app on the repo (free for public repos).
8. Smoke test, in order:
   - `gh workflow run agent-backlog.yml -f dry_run=true` and read the run summary
   - file a tiny issue yourself, run the backlog for real, check its labels and assessment comment
   - `gh workflow run agent-dev.yml -f issue=N` and watch the PR, review, and followup

## Day to day

- **Rough idea:** file an issue. The backlog run expands it, asks questions, or splits it.
- **Answering questions:** comment on the issue. Any comment from you triggers reassessment the next night. Comment `/reassess` to force it.
- **Urgent:** add the `agent:urgent` label, or `gh workflow run agent-dev.yml -f issue=N`.
- **Dependencies:** write `Blocked by #N.` in the issue, or mark it as blocked in the issue sidebar (GitHub's native issue dependencies). Either one is enough: the issue is skipped by triage and dev until every such blocker is closed. `not blocked by #N` and a quoted "Blocked by" are ignored. A manual run (`-f issue=N`) overrides both.
- **Base branch:** to have an issue worked on a branch other than the default, put `Base: feat/my-branch` on a line of its own in the issue body, or add a label `base:feat/my-branch`. See "Per-issue base branch" below.
- **Milestones:** the nightly dev run takes ready issues from the most pressing open milestone first. See "Order of work" below.
- **Someone else's issue:** file your own issue that links to theirs. The loop never works external issues.
- **Found issues:** problems the dev agent notices but doesn't fix get filed as new issues (as you, labeled `agent:found`, max 3 per worked issue, duplicates by title skipped) and go through normal triage.
- **Stopped work:** issues the agent gives up on get `needs:human` and a comment saying why. Too-big issues get a split suggestion.

## Dependencies

Two sources, and an issue is blocked if either says so:

- **Text:** `Blocked by #N` / `after #N merges` in the issue body (`lib/blocked.jq`).
- **Native:** GitHub's issue dependencies. `native-blockers.sh` reads `blockedBy` for all open issues in one paginated GraphQL query and `lib/native-blockers.jq` reduces it to `{"<issue>": [open blocker numbers]}`, which the selection filters take as `--argjson native`. Closed blockers do not count. A blocker in another repository counts while it is open.

If the dependencies query fails (API unavailable, token cannot read it), the run logs a warning and carries on with the text form only. It does not fail, and it does not treat everything as blocked.

## Per-issue base branch

By default the dev agent checks out `base_branch` (default `main`), branches from it, and opens its PR against it. An issue can name another branch:

- body line: `Base: feat/multi-target` (on its own line, backticks around the name allowed), or
- label: `base:feat/multi-target`

Rules, enforced by `lib/base.jq` and `resolve-base.sh` before anything is checked out:

- **Precedence:** the body line wins over the label. Two different `Base:` lines, or two `base:` labels, are an error.
- **Validation:** only plain branch names: letters, digits, `.`, `_`, `-`, `/`, starting with a letter or digit, at most 100 characters; no `..`, `//`, leading-dot or `.lock` components, trailing `/` or `.`, `HEAD`, or `refs/...`. A malformed value is an error; it never falls back to the label or the default.
- **Existence:** the branch must already exist. The agent does not create base branches.
- **Not the agent's own branches:** `issue-N` branches hold the agent's unreviewed work and are refused as a base.
- **Only your words count:** a `Base:` line is honoured because the issue body is yours. Bodies the model writes are not: found issues and split children have any `Base:` line rewritten to `Suggested base (not applied):` before they are filed, and a `Base:` line in the body of an `agent:found` issue is refused. To give such an issue a base, add a `base:<branch>` label.
- **On any error** the issue is handed back like other failures: `agent:ready` is replaced by `needs:human` and a comment says why. The digest shows `bad_base`.

The PR is opened against that branch, and review and followup work from the PR's actual base: the review diff uses the PR's base commit, and `enable-automerge.sh` checks the ruleset of the PR's base branch. A feature branch without required status checks therefore never gets auto-merge; merge those PRs yourself.

GitHub only acts on `Closes #N` when a PR merges into the default branch. When the base is another branch, the dev job removes `agent:ready` once the PR is open, so the issue is not worked a second time after the merge, and says so in the digest. Close the issue yourself when you merge; if triage marks it `agent:ready` again before you do, it will be worked again.

## Order of work

The nightly dev run picks up to `max_issues` ready issues in this order (`lib/select.jq`):

1. Issues in the preferred milestone, oldest first.
2. Everything else (other milestones and no milestone alike), oldest first.

The preferred milestone is the open milestone with the earliest due date among those that have at least one ready, unblocked issue. Milestones with a due date come before those without; ties and undated milestones go by lowest milestone number. With no open milestones the order is simply oldest first.

## Adapting to another language

Set `verify_command`, `bash_allow`, `protected_paths`, and either `go_version_file` or `setup_command`. Example for a C project built with make:

```yaml
setup_command: sudo apt-get update && sudo apt-get install -y build-essential
verify_command: make && make check
bash_allow: Bash(make),Bash(make check),Bash(make clean)
protected_paths: |
  Makefile
  configure
```

A repo with no automated tests is not a loop candidate. Its first issues should build a CI build check and a smoke test, worked by hand.

## Direct pushes

The ruleset's empty bypass list is what stops the PAT (which acts as you) from skipping checks. It also stops you. Options: work through PRs (`gh pr create --fill && gh pr merge --auto --squash`), or keep the loop on repos where that's acceptable.

## Testing this repo

`bash test/run.sh` runs offline tests of the selection, candidate, dependency, base-branch, milestone, plan-validation, followup, diff-check, and prompt-render logic. `actionlint` and `shellcheck` should be clean.

## Known limits and residual risk

- The Claude token is in the environment while Claude runs tests it wrote. Only your own issues reach that step, so a hostile prompt would have to come from you. A leaked token costs usage, not code.
- GitHub scheduled runs can start late under load.
- Native dependencies are read up to 50 blockers per issue; an issue with more is treated as blocked.
- A PR against a non-default base does not close its issue on merge (see "Per-issue base branch").
- Cron times are UTC; Eastern times shift by an hour at DST.
- `make golden-update` (or similar) lets the agent regenerate golden files. The review prompt checks for weakened tests, but read golden diffs yourself.
- The fix round trusts CodeRabbit's comments as feedback. They are still treated as code feedback, never as instructions about credentials or CI.
