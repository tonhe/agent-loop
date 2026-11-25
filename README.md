# agent-loop

Reusable GitHub Actions workflows that run Claude Code as an unattended issue-to-PR loop on public repos, with the guardrails enforced in scripts rather than prompts.

```
1:17 AM  backlog   triage the owner's issues -> labels, assessment, splits
                   + propose: "Release vX.Y.Z" issue, "Plan vX.Y" issue (never tags, never moves milestones)
2:17 AM  dev       up to 3 agent:ready issues, one job each -> PR as the owner
on PR    review    Claude review (required check) + CodeRabbit
                   loop PRs: blocking; your own PRs: advisory, one comment kept up to date
after    followup  one fix round -> auto-merge if risk:low
always   digest    Discord message per run
```

Each project repo carries only four small caller workflows (`examples/caller/`). Everything else lives here, pinned by tag.

## Guardrails and where they are enforced

| Guardrail | Enforced by |
|---|---|
| Blocked issues wait: "Blocked by #N" (or "after #N merges") while #N is open, a blocker with no number, or an open blocker in GitHub's native issue dependencies keeps an issue out of triage and dev | `lib/blocked.jq`, `lib/native-blockers.jq`, `native-blockers.sh` |
| The blocker audit only ever adds a native dependency between two of your own open issues of this repository, where the text names the blocker plainly; at most `max_blocker_links` per run. It never removes a link, never edits an issue, and its failure changes nothing for triage and dev | `lib/audit-blockers.jq` (`audit_plan`, `direct_blockers`), `audit-blockers.sh` (own query, one kind of write) |
| A per-issue base branch must be a plain branch name that already exists; anything else hands the issue back | `lib/base.jq`, `resolve-base.sh` |
| Only the owner's issues are ever shown to Claude | `select-issues.sh`, `issue-context.sh`, `lib/candidates.jq` (author check); the review of an owner PR reads linked issues through `issue-context.sh` too (`review-linked.sh`) |
| Other people's comments never reach Claude | `issue-context.sh`, `review-context.sh` (owner, CodeRabbit, github-actions only) |
| From the body of an owner PR, which a model may have written, only issue numbers are taken: at most 5, this repository only | `lib/review.jq` (`linked_issues`), `review-linked.sh` |
| A model cannot block your own PR: the review of an owner PR is advisory, and a Claude failure, a timeout, a malformed result or a broken review step also ends in success | `review-post.sh` (owner mode exits 0), `advisory.sh` around every review step, `continue-on-error` on the two steps that are not scripts |
| On an owner PR nothing counts as approval of a protected file: every protected file changed is listed in the review by script, an "Owner decision" comment is only quoted next to it | `review-protected.sh` (`MODE=owner`), `lib/glob.jq` (`owner_protected`) |
| An owner review can never be taken for a loop review, and never stacks: its own marker, one comment updated in place, found by marker and by author `github-actions[bot]` | `lib/review.jq` (`review_marker`, `existing_review_comment`), `review-post.sh` |
| Model text in a posted review cannot open an HTML comment, so it cannot plant a loop marker | `lib/review.jq` (`review_combine`) |
| A loop PR never passes on a review that did not see everything: a diff that had to be cut, a changed file that is in no prompt, a failed call or a result that is not a review all fail the check | `review-prompts.sh` (size and coverage checks), `review-calls.sh`, `lib/review.jq` (`valid_review`, `review_combine`), `review-post.sh` |
| File names from a diff are data: literal git pathspecs after `--`, or text in a code span | `review-prompts.sh`, `lib/split.jq`, `lib/review.jq` |
| Backlog manager can't do anything directly | Read-only tools; returns JSON that `lib/validate-plan.jq` filters |
| `agent:ready` only for `risk:low`; human-set labels kept; `agent:urgent` untouchable | `lib/validate-plan.jq` |
| `agent:paired` issues are never picked by the nightly dev run and never re-routed or split by triage; the label cannot be added or removed by the plan | `lib/select.jq`, `lib/validate-plan.jq` |
| Triage never changes a label on an issue with an "Owner decision" comment (yours, starting with `Owner decision`; the same test as for protected paths): no label added or removed, routing, risk and type alike, and no split. It may only post its assessment | `lib/candidates.jq` records the fact from the comments (`owner_decision`, using `owner_decisions` in `lib/glob.jq`); `apply-backlog.sh` passes it on; `lib/validate-plan.jq` drops the changes |
| Triage can never set a milestone | `schemas/backlog-plan.json` has no such field; `lib/validate-plan.jq` builds its output field by field, so one smuggled in is dropped; `apply-backlog.sh` never passes one to `gh` |
| Release issues only propose: never a tag, never a GitHub release, never a deployment approval | `release-issue.sh` only creates or edits one issue; PAT has no Deployments permission |
| Only a Release issue the loop filed is ever edited (exact title, owner as author, `release` label and the `<!-- agent-release -->` marker); one you wrote by hand is left alone and not duplicated | `lib/release.jq` (`existing_release`, `handwritten_release`) |
| Commit messages in a Release issue are data: never evaluated, mentions and HTML comments neutralised, never at the start of a line (so never a `Base:` line) | `lib/release.jq` (`safe_line`, `release_body`), `release-issue.sh` (files and `--body-file` only) |
| Milestone planning only proposes: no milestone created or assigned, no label changed; the Plan issue carries `needs:human` and nothing else | `plan-due.sh` (read-only), `apply-backlog.sh`, `lib/planning.jq` |
| A plan proposal can only name the owner's issues it was offered; model text is cut to single lines and defanged | `lib/planning.jq` (`plan_due`, `plan_body`) |
| Release and Plan issues are never triaged or worked (their text is not yours) | `lib/meta.jq`, used by `lib/candidates.jq`, `lib/select.jq`, `select-issues.sh`, `issue-context.sh` |
| Issues the model words (split children, found issues) cannot pass for a Release or Plan issue: a title starting `Release v…` or `Plan v…` gets `Re: ` in front, and no `<!-- agent-` marker survives in the body | `lib/meta.jq` (`safe_title`, `defang_markers`), `apply-backlog.sh`, `file-found.sh`; `lib/release.jq` and `lib/planning.jq` also require their own marker before treating an issue as theirs |
| A loop PR touching a protected-by-instruction path needs your "Owner decision" comment on the issue | `review-protected.sh`, `lib/glob.jq` block without the model; the reviewer judges scope when a decision exists |
| The model cannot choose which issue a loop PR belongs to: not for the review, not for follow-up and auto-merge, not for selection | One rule in `lib/pr.jq`: the number is the `N` of the head branch (`issue-N`, set by `publish-pr.sh`); the body marker can only agree or not. `review-gate.sh` fails the check unless it agrees. `lib/followup.jq` and `followup.yml` read the issue's labels and text by the branch's number, and never auto-merge when the marker is missing or names another issue. `publish-pr.sh` neutralises `agent-loop issue=` and HTML comments in the model's PR text; `issue-context.sh` refuses Release and Plan issues |
| Only your own PR can keep an issue out of the nightly run | `lib/select.jq`: issue N counts as having an open PR only when a PR opened by `owner_login`, not from a fork, is on branch `issue-N`. The PR body is not read, so a missing or wrong marker never frees an issue whose branch would be force-pushed, and a stranger's PR never blocks one |
| No network tools, no MCP, narrow Bash allowlist | `run-claude.sh` (`--tools`, `--allowedTools`, `--strict-mcp-config`, `--permission-mode dontAsk`) |
| Token limits | `--max-turns`, wall-clock `timeout`, job `timeout-minutes`, max issues per run, model per job; a review is at most `split_max_calls` calls inside one shared time budget (`review-calls.sh`) |
| Agent can't touch CI, Makefile, coverage floors | `check-diff.sh` (`.github/` always, plus `protected_paths`); PAT lacks Workflows permission |
| "Done" means verified | Workflow re-runs `verify_command` itself in a step with no secrets |
| Agent code never runs next to the PAT | Verify step has no secrets; publish step applies a patch in a fresh checkout with hooks disabled |
| One fix round only | Marker comment posted before the round starts (`lib/followup.jq`); the round works on the issue of the PR's branch (`issue-N`, `lib/pr.jq`) |
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
   - `agent-dev.yml` needs `actions: read` under `permissions:` (the example has it). The nightly dev run uses it to see whether a backlog run is still going and waits for it. If you copied the callers before this was added, add the line; without it the run warns and starts without waiting.
   - If your backlog caller is not named `agent-backlog.yml`, set `backlog_workflow: <file name>` in the `with:` block of `agent-dev.yml`. `backlog_wait_minutes` (default 15, at most 20) is the longest wait; `0` switches it off. See "Order of work".
2. Secrets (`gh secret set NAME -R owner/repo`, paste when prompted):
   - `CLAUDE_CODE_OAUTH_TOKEN`
   - `AGENT_PAT`
   - `DISCORD_WEBHOOK_URL` (optional)
3. Labels: `scripts/bootstrap-labels.sh owner/repo`. Safe to re-run; run it again after upgrading to pick up new labels (`agent:paired`, `release`, `stretch`).
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
- **The nightly selection, now:** `gh workflow run agent-dev.yml -f mode=scheduled` picks issues exactly as the nightly run does.
- **Dependencies:** write `Blocked by #N.` in the issue, or mark it as blocked in the issue sidebar (GitHub's native issue dependencies). Either one is enough: the issue is skipped by triage and dev until every such blocker is closed. `not blocked by #N` and a quoted "Blocked by" are ignored. A manual run (`-f issue=N`) overrides both.
- **Base branch:** to have an issue worked on a branch other than the default, put `Base: feat/my-branch` on a line of its own in the issue body, or add a label `base:feat/my-branch`. See "Per-issue base branch" below.
- **Milestones:** the nightly dev run takes ready issues from the most pressing open milestone first, then other milestones, then issues without one. See "Order of work" below. Triage never assigns milestones; you do.
- **Bugs first:** set `selection_order: type` in `agent-dev.yml` so a new bug does not wait behind older feature issues. See "Order of work".
- **Pairing with your own agent:** label an issue `agent:paired` when your interactive agent owns it. The nightly dev run never picks it up, and triage still assesses it and sets risk/type labels but leaves its routing alone: no `agent:ready`, no `needs:human`, no split, and the label itself is never added or removed by the loop. `gh workflow run agent-dev.yml -f issue=N` (and `agent:urgent`) still runs it: asking for an issue by number is your approval, the same way it overrides blockers. Remove the label to hand the issue back to the loop.
- **Releases:** when a release looks due the backlog run opens `Release vX.Y.Z`, assigned to you. It never tags. See "Release issues".
- **Planning:** when the active milestone runs low the backlog run opens `Plan vX.Y` with a proposal. Answer in the issue; nothing is moved for you. See "Milestone planning".
- **Your own PRs:** a PR you open from a branch of the repo (by hand or through your interactive agent) gets an advisory review: one comment, updated on every push, and the check passes whatever it says. Write `Fixes #N` (or `Closes`, `Resolves`, `Refs`) in the body to have it reviewed against your issue. Each push costs at least one Claude call. See "Review modes".
- **Protected files:** if an agent PR is blocked for touching a protected-by-instruction path, comment on the issue starting with `Owner decision` and say what may change, then re-run the review. See "Protected by instruction".
- **Someone else's issue:** file your own issue that links to theirs. The loop never works external issues.
- **Found issues:** problems the dev agent notices but doesn't fix get filed as new issues (as you, labeled `agent:found`, max 3 per worked issue, duplicates by title skipped) and go through normal triage. Like split children, they cannot be titled like a Release or Plan issue: such a title is filed as `Re: Release v…` / `Re: Plan v…`.
- **Stopped work:** issues the agent gives up on get `needs:human` and a comment saying why. Too-big issues get a split suggestion.

## Dependencies

Two sources, and an issue is blocked if either says so:

- **Text:** `Blocked by #N` / `after #N merges` in the issue body (`lib/blocked.jq`).
- **Native:** GitHub's issue dependencies. `native-blockers.sh` reads `blockedBy` for all open issues in one paginated GraphQL query and `lib/native-blockers.jq` reduces it to `{"<issue>": [open blocker numbers]}`, which the selection filters take as `--argjson native`. Closed blockers do not count. A blocker in another repository counts while it is open.

If the dependencies query fails (API unavailable, token cannot read it), the run logs a warning and carries on with the text form only. It does not fail, and it does not treat everything as blocked.

### Blocker audit

The loop honours either source, but GitHub's own display (the issue sidebar, "blocked" in lists, milestone progress) uses the native link only. An issue with the text and no link looks unblocked on GitHub. The backlog run therefore compares the two every night, by script (`audit-blockers.sh`, decided by `lib/audit-blockers.jq`; no model call):

- **Text names an open blocker, no native link:** the link is added (`POST repos/{repo}/issues/{n}/dependencies/blocked_by`). Only when both issues are open, yours (`owner_login`) and in this repository, and the text names the blocker plainly: `Blocked by #4`, `Blocked by #4, #5 and #6`, `… and by #4`, `after #4 merges`. A number that merely appears in the sentence (`Blocked by the design issue under #6`) is reported, not linked.
- **Native link to an open blocker, not in the text:** reported only. Issue bodies are never edited; the link alone already blocks.
- **Left alone, and not reported:** a blocker that is closed, a pull request or a number that does not exist; a blocker with no number; `owner/repo#N`; Release and Plan issues, on either end; issues written by someone else. A blocker someone else wrote is reported, never linked.

The digest lists every link added and every mismatch as `#N`, and says nothing when text and links agree. At most `max_blocker_links` (default 10) links are added per run; the rest are listed and picked up the next night. With `dry_run: true` it prints what it would add. A failed audit is a warning: the run does not fail, and triage and dev see exactly what they saw before (the audit reads with its own query).

- **Off switch:** `blocker_audit: off` on the backlog workflow. `blocker_audit: report` keeps the report and adds nothing. The default is `fix`.
- **Undoing a link:** remove it in the issue sidebar. If the text still names the blocker, the next run adds it again, so change the text too.

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

1. Issues in the preferred milestone.
2. Issues in any other open milestone.
3. Issues with no milestone. An issue whose milestone is closed counts here.

The preferred milestone is the open milestone with the earliest due date among those that have at least one ready, unblocked issue. Milestones with a due date come before those without; ties and undated milestones go by lowest milestone number (`lib/milestone.jq`). With no open milestones, or when the milestone list cannot be read, everything is in group 3.

Inside each milestone group the order is set by the dev workflow input `selection_order`:

- `oldest` (the default): oldest first by creation date. Nothing else is looked at.
- `type`: by label group, oldest first inside each group:
  1. `type:bug`
  2. `tech-debt` (the plain label, not a `type:` label)
  3. `type:refactor`, `type:chore`, `type:test`, `type:docs` (one group)
  4. `type:feature`
  5. issues with none of these labels

  An issue that fits several groups counts in the earliest one, so a `type:bug` that is also `tech-debt` is a bug.

Pick `type` when the backlog holds old feature or stretch issues: with `oldest` a bug filed today waits behind all of them, with `type` it goes next. Milestones always rank above the type group: a feature in the preferred milestone is worked before a bug with no milestone. Any other value fails the select job with an error. To turn it on, add to the `with:` block of `agent-dev.yml`:

```yaml
      selection_order: type
```

`agent:paired` issues and the loop's own Release and Plan issues are never in the list.

Before it selects, a run in mode `scheduled` checks for a run of the backlog workflow (`backlog_workflow`, default `agent-backlog.yml`) that has not finished, whether in progress, queued or held back, and waits for it, so it does not pick from labels that triage is about to change (`scripts/wait-backlog.sh`). It checks every 30 seconds for at most `backlog_wait_minutes` (default 15, at most 20; `0` = never wait), then selects either way. The digest says when a run waited and when it gave up waiting. Manual and urgent runs name their issue and never wait. If the runs cannot be listed (no `actions: read` in the caller, wrong file name, GitHub error), the run log carries a warning and selection starts at once.

## Release issues

The backlog run looks at the commits on the default branch since the latest `vX.Y.Z` tag and, when a release is due, opens one issue titled `Release vX.Y.Z` (label `release`, assigned to `owner_login`). It proposes; you tag. `release-issue.sh` only creates or edits that issue. It never creates a tag, never creates a GitHub release and never approves a deployment.

- **Tag:** the highest tag of the exact form `vX.Y.Z` by version number. Other tags (`v1`, `v1.2`, `v1.2.3-rc1`) are ignored. No such tag: nothing happens, with a note in the run summary. No commits since the tag: nothing happens.
- **Version:** minor bump (`vX.(Y+1).0`) if any commit since the tag is a `feat` (`feat:` or `feat(scope):`) or is marked breaking (`!` before the colon, or a line starting `BREAKING CHANGE:` in the message); otherwise a patch bump. It never proposes a major bump.
- **When:** either (a) the oldest unreleased `fix` commit landed more than 7 days ago (committer date), or (b) the open milestone that matches the proposed version (see "Would slip") has no open issues left and at least one closed one. A milestone nothing was ever put in does not count as finished, and neither does a finished milestone for another version or one that is not named after a version.
- **Body:** why now, draft release notes (Breaking, Features, Fixes), the commits grouped by prefix (`feat`, `fix`, other prefixes by name, then commits without one), and the open issues that would slip. Each notes section and each prefix group lists up to 50 entries and counts the rest. The whole body stays at or under 60,000 characters (GitHub refuses more than 65,536): if the commit list does not fit it is cut and ends with `…and N more commit(s) not listed here`; the rest of the body is never cut.
- **Would slip:** open issues, by number, in the matching milestone. A milestone matches when its title, trimmed, is exactly `vX.Y.Z`, `X.Y.Z`, `vX.Y` or `X.Y` for the proposed version; the full version wins over the short form. So `v1.2` matches `v1.2.0` and `v1.2.4`; `v1.2.0 beta` and `Release v1.2.0` match nothing.
- **One issue:** an open release issue is found by exact title `Release vX.Y.Z`, you as author, the `release` label and the `<!-- agent-release -->` marker in the body, all four. If one is open its body is refreshed (only when it changed) instead of opening another; this also happens on nights when neither trigger holds, so the list stays current. If the version changed (a `feat` landed after a patch issue was opened) the same issue is retitled. An issue someone else opened with the same title is never touched. Close the issue after you tag.
- **Your own Release issue:** an open issue of yours titled `Release vX.Y.Z` that the loop did not file (no marker, or no `release` label) is never edited. While it is open and a release for that version is due, no second issue with that title is opened and none is retitled to it; the run summary and the Discord digest say so each night. Close or rename yours to get the proposal.
- **Discord:** one line when an issue is opened, retitled or refreshed. No webhook, or a failed post, does not fail the run.
- **Dry run:** prints what it would do and changes nothing.
- **Untrusted text:** commit messages are not your words. Each subject is cut to one line, `@` cannot notify, an HTML comment cannot open, and commit text is only ever placed after a prefix the script chose (a list dash, a heading), so it cannot begin a line and cannot form a `Base:` line; the body also goes through `defang_base`. The issue is never triaged and never worked by the dev agent (`lib/meta.jq`), so that text does not reach Claude.
- **Off switch:** `release_issues: false` on the backlog workflow.

Data comes from the GitHub API (tags, `compare/<tag>...<default branch>`, milestones, open issues), so the shallow checkout is enough. The `release` label is created by `bootstrap-labels.sh`; if it is missing the script creates it before filing.

## Milestone planning

When the active milestone has 3 or fewer open issues, the backlog run opens `Plan vX.Y` (label `needs:human`, assigned to `owner_login`) with a proposal for you to answer in the issue. It never creates a milestone, assigns one or changes a label.

- **Active milestone:** the same rule as the preferred milestone in "Order of work" (`lib/milestone.jq`), but over the open milestones that still hold any open issue rather than only ready ones. If no open milestone holds an open issue, the rule runs over all open milestones. The count is GitHub's open count for the milestone.
- **Version:** the next minor after the latest `vX.Y.Z` tag: tag `v0.2.1` gives `Plan v0.3`.
- **Off when:** there is no open milestone, there is no `vX.Y.Z` tag, or the loop already filed a `Plan vX.Y` issue for that version (exact title, you as author, and the `<!-- agent-plan -->` marker in the body), open or closed. A closed one counts so that an answered plan is not asked again every night; rename it if you want a fresh proposal. An issue with that title that the loop did not file (one you wrote by hand, or anything without the marker) does not count, so a proposal is still opened next to it.
- **Who decides what:** `plan-due.sh` and `lib/planning.jq` decide when. What to propose is the backlog manager's judgement: it is given the active milestone's open issues, your unmilestoned issues and your `stretch` issues (numbers, titles and labels of issues you opened, nobody else's) and the roadmap path, and reads the roadmap itself with its read-only tools.
- **Proposal:** the next epic from the roadmap's ordered list, up to 5 unmilestoned features ranked by value and size, `stretch` issues worth promoting, and anything in the active milestone that should move out. Each item has a one-line size estimate and a recommendation.
- **Roadmap:** `ROADMAP.md` at the repository root, or the path in `roadmap_path`. If the file does not exist the issue is still opened, without an epic, and says so.
- **Guardrails:** the body is rendered by `lib/planning.jq`: an item naming an issue that was not offered for its section is dropped (and counted in the issue), titles come from your issues rather than from the model, model text is cut to single lines, and the result goes through `defang_base`. It is filed with the PAT in the existing apply step with the single label `needs:human`. The Plan issue is never triaged or worked afterwards. A proposal that cannot be rendered at all (the model returned the wrong shape) files nothing, the digest says `planning: proposal could not be rendered`, and triage is unaffected; it is asked for again the next night.
- **Cost:** on a night when planning is due, Claude runs even if there is nothing to triage. If that run fails, the digest says planning was due and gives the job status; "Nothing new to triage." is only said when there was nothing for Claude to do (`scripts/backlog-digest.sh`).
- **Dry run:** the proposal is asked for and reported; no issue is filed.
- **Off switch:** `milestone_planning: false` on the backlog workflow.

## Review modes

The review workflow (`review.yml`, job `agent-review`) sorts every pull request with `scripts/review-gate.sh`:

| PR | Mode | What happens |
|---|---|---|
| Opened by `owner_login`, head branch `issue-N`, body marker `agent-loop issue=N` | `loop` | Reviewed against issue N. **Blocking**: the check fails unless the verdict is pass. |
| Opened by `owner_login` from a branch of this repository, any other branch name, no marker | `owner` | Reviewed against the issues it links, or on the diff alone. **Advisory**: the check always passes. |
| From a fork, or opened by anyone else | none | Passes straight through. Nothing is checked out, Claude is not asked. |
| `issue-N` branch without a matching marker, a marker on another branch, a second marker naming another issue | none | The check fails rather than guessing. Do not name your own branches `issue-N`. |

### Loop mode

Unchanged: the dev agent's PR is reviewed against its issue, a non-pass verdict or a failed Claude call fails the check, and a protected file changed without an "Owner decision" comment is blocked before Claude is asked (see "Protected by instruction"). Each run posts a new comment that begins `<!-- agent-review -->`.

### Owner mode

For the PRs you push yourself, including the ones your local or interactive agent opens under your login.

- **Advisory, always.** The comment is headed `Agent review (advisory): PASS`, `BLOCK`, `... (INCOMPLETE)` or `NOT COMPLETED`, and the `agent-review` check ends in success whatever it says. A model must not be able to block your merge, so a Claude failure, a timeout, a result that is not a review, or an error in any review step also ends in success: the comment (or, if not even that can be posted, the run summary) says the review could not be completed, and the run carries a warning. `review-post.sh` exits 0 in owner mode and every review step runs under `advisory.sh`.
- **One comment per PR.** The comment begins `<!-- agent-review-owner -->`. On each push the bot's existing comment with that marker is updated in place; a new one is created only when there is none. It says which commit it is for. The comment is found by marker and by author `github-actions[bot]`, so a comment of yours that quotes the marker is never overwritten. The followup workflow only handles PRs on an `issue-N` branch, so it never sees an owner PR.
- **Linked issues as context.** Issue numbers are taken from the PR body: `Fixes #N`, `Closes #N`, `Resolves #N`, `Refs #N` (and `fix`, `fixed`, `close`, `closed`, `resolve`, `resolved`, `ref`), any case, an optional colon, number on the same line. Limits: `#N` of this repository only (`org/repo#5` and issue URLs are ignored), no leading zeros, duplicates count once, at most 5. Nothing else is read from the PR body, which your agent may have written: not its text, not its title. Each number goes through `issue-context.sh`: the issue is used only if you opened it and it is not a Release or Plan issue, and only your comments on it are included. Anything else is skipped with a line in the log. With no usable linked issue the PR is reviewed on its diff alone, and both the prompt and the comment say so.
- **Protected paths.** Nothing is blocked and nothing is approved. See "Protected by instruction".
- **Cost.** Every push to one of your PRs now runs at least one Claude call (several for a large PR, see below). The example caller cancels a running review when a new push arrives (`cancel-in-progress`), so only the latest push is reviewed to the end.

### Large PRs (both modes)

A PR that touches more than `split_max_files` files (40) or has more than `split_max_lines` changed lines (3,000; added plus deleted from `git diff --numstat --no-renames`, so a rename counts as a deletion and an addition; binary files count as files only) is reviewed in several Claude calls instead of one prompt:

1. Files are grouped by top-level directory; root-level files are their own group.
2. A group that is itself over a threshold is divided one level deeper, and again, until every group fits or is a single file. Files that sit directly in a directory that had to be divided form their own group, cut into parts if there are too many.
3. Small groups are packed together so the number of calls stays low.
4. If that still gives more than `split_max_calls` groups (8), the smallest are merged until it fits, and the review says so.
5. A group whose diff is larger than `split_max_diff_bytes` (300,000) is cut into smaller groups file by file, as far as the call limit allows, so that no diff has to be truncated when a finer split avoids it.

The plan is a pure function (`lib/split.jq`: `parse_numstat`, `split_plan`, `refine_plan`). Each call gets the same header, the issue context, the protected-path section, the list of the other parts' paths (so the reviewer knows what it is not seeing), and only its own part's diff. The calls run one after the other. ONE review is posted: a summary per part, all findings merged with their file and line, and the overall verdict is the worst of the parts (pass only if all pass).

Nothing goes unreviewed silently:

- **A diff that still does not fit** (a single file whose own diff is over `split_max_diff_bytes`, or a group left over when the call limit is used up). Loop mode: the check fails with "too large to review completely"; a loop PR is never passed on a cut diff. Owner mode: the diff is cut, the prompt carries a "diff truncated" note, and the review names the files that were not fully shown and is marked incomplete.
- **A file in no part's diff.** The plan is built from text, and a file name that is not valid UTF-8 does not survive that. After the prompts are built, the files in them are compared byte for byte with the files git says changed. Loop mode: the check fails and says how many files are missing. Owner mode: the review lists them as not reviewed.
- **A call that fails.** Loop mode: the check fails, as before. Owner mode: the comment names the part that was not reviewed and the other parts still count.

Timeouts: each call is limited by `timeout_minutes` (15) and `max_turns`. The job is limited by `job_timeout_minutes` (120). The calls share that minus 15 minutes: a call gets what is left, at most `timeout_minutes`, and a call that cannot start any more counts as failed. So the job's own timeout, which would fail the check in either mode, is not reached by the calls.

Inputs of `review.yml` for this, all optional:

| Input | Default | Meaning |
|---|---|---|
| `split_max_files` | 40 | more files than this: split |
| `split_max_lines` | 3000 | more changed lines than this: split |
| `split_max_calls` | 8 | most Claude calls for one review |
| `split_max_diff_bytes` | 300000 | largest diff in one prompt |
| `job_timeout_minutes` | 120 | timeout of the whole review job |

Existing callers need no change: every earlier input keeps its name and default.

## Protected by instruction

`protected_paths` (dev and followup workflows) hard-blocks the dev agent: a change to those files is discarded by `check-diff.sh`. `protected_review_paths` (review workflow) is for files the agent may change, but only when you said so for that issue. Callers pass it to `agent-review.yml`:

```yaml
      protected_review_paths: |
        internal/probe/family.go
        internal/sysprobe/**
        cmd/via/*.go
```

When a loop PR (the dev agent's) changes a matching file, the review looks on the linked issue for a comment written by `owner_login` that begins with `Owner decision` (leading blank space and Markdown heading or bold marks are allowed; case matters) and names the approved scope, for example `Owner decision: family.go may change, only the fallback order.` The phrase has to stand on its own: after it comes a colon, a space, a line break or the end of the comment. A comment starting `Owner decisions are pending` or `Owner decision-making` is not a decision.

- **No such comment:** `review-protected.sh` posts a blocking review comment listing each file and the pattern that protects it, and fails the `agent-review` check. Claude is not asked.
- **A comment exists:** the matched files and your comment go into the review prompt, and the reviewer blocks if the diff goes beyond the scope you named, saying which files and why.

Only your comments count, with the same filtering as `issue-context.sh`. Comments the loop posts under your name (assessments, hand-backs) carry an `<!-- agent-` marker and never count. After adding the comment, re-run the failed review job; a comment alone does not re-trigger it.

Pattern syntax (`lib/glob.jq`), one per line, blank lines and `#` comments ignored:

| Pattern | Matches |
|---|---|
| `internal/probe/family.go` | that file only |
| `cmd/via/*.go` | `.go` files directly in `cmd/via`; `*` and `?` never cross a `/` |
| `internal/sysprobe/**` | everything under `internal/sysprobe`; `**` crosses `/`, and `a/**/b` also matches `a/b` |
| `internal/sysprobe/` or `internal/sysprobe` | the same: a pattern that matches a directory covers everything under it |

Patterns are anchored at the repository root, match the whole path and are case-sensitive; a leading `./` or `/` is dropped. There are no `[classes]`, `{a,b}` or `!` negation. Renames count on both sides, so moving a file out of a protected directory is a change to it. A file name containing a quote, a backslash or a control character counts as protected.

The blocking check applies to loop PRs only: opened by you, not from a fork, on a head branch named `issue-N`, with the `agent-loop issue=N` marker in the body. The issue is the `N` of the branch name, which `publish-pr.sh` sets; the body is partly model text, so it is only checked for agreement (`scripts/review-gate.sh`). If the two disagree, or only one of them is there (an `issue-N` branch without the marker, a marker on another branch, a second marker naming another issue), the `agent-review` check fails rather than guessing. So do not name your own branches `issue-N`. Fork PRs and other people's PRs pass straight through the review workflow as before. An empty `protected_review_paths` turns the feature off and nothing changes.

**On your own PRs (owner mode)** the rule is different, because the PR body may be model text and it is the body that names the linked issues:

- An "Owner decision" comment never counts as approval and never suppresses anything.
- Every protected file the PR changes is listed in the posted review, in its own "Protected paths" section, with the pattern that protects it. The section is written by `review-protected.sh` (`lib/glob.jq`, `owner_protected`), not by the model, from the same changed-file list as in loop mode (deletions, files moved out, mode-only changes and unusual names all count).
- Next to the list the section quotes your comments beginning `Owner decision` found on the linked issues that were accepted as context (yours, not Release or Plan issues), each under its issue number, "for the owner to judge", or says that none was found. They are not checked against the diff.
- The check never fails for this, and the loop's blocking comment is never posted. The reviewer is told to look at those files with extra care and that approval is your call.

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

`bash test/run.sh` runs offline tests of the selection, selection-order, candidate, dependency, base-branch, milestone, plan-validation, release, planning, protected-path, review-gate, owner-mode (linked issues, protected listing, advisory exit, comment update), review-split, review-coverage, digest, followup, diff-check, and prompt-render logic. `actionlint` and `shellcheck` should be clean. The Worker has its own tests: `npm test` in `worker/` (Node 20 or later, no dependencies).

## Known limits and residual risk

- The Claude token is in the environment while Claude runs tests it wrote. Only your own issues reach that step, so a hostile prompt would have to come from you. A leaked token costs usage, not code.
- GitHub's `schedule:` trigger is best effort. On one repo it started runs 6 to 12 hours late and dropped most slots of a three-hourly job. If that happens, remove the `schedule:` blocks from the callers and start the workflows from outside: `worker/` is a Cloudflare Worker that does it, checks that each run was created, and reports failures to Discord.
- Native dependencies are read up to 50 blockers per issue; an issue with more is treated as blocked.
- A PR against a non-default base does not close its issue on merge (see "Per-issue base branch").
- Release issues read the commit list through the compare API and open issues up to 500; planning reads the first 200 open issues.
- A release issue is proposed from commit prefixes. Commits without a conventional prefix are listed but never raise the version.
- Whether a diff stays inside an "Owner decision" scope is the review model's judgement. That a decision comment exists at all is checked by script.
- The review of your own PRs is advisory by design: a `BLOCK` there does not stop a merge, and a review that failed looks like a passed check with a warning. Read the comment.
- An owner PR's linked issues are chosen by its body, which your agent may have written. Only your own issues and comments can be pulled in that way, never anyone else's text.
- A large PR is reviewed in parts by separate calls. Each sees the other parts' file names, not their diffs, so a problem that only shows across parts can be missed.
- Split planning counts a rename as a deletion plus an addition, so a PR that moves many files is split sooner than its real size suggests.
- A changed file whose name is not valid UTF-8 cannot be put into a split review: a loop PR with one fails the check, an owner PR lists it as not reviewed. A PR under the split thresholds is not affected.
- The review job fails if the agent-loop checkout or the gate itself fails, before the mode is known. Past the gate, an owner PR cannot be failed by the review.
- Cron times are UTC; Eastern times shift by an hour at DST.
- The nightly dev run waits for a backlog run that exists when it starts, for at most 20 minutes. A backlog run started after the selection, or one still going when the wait gives up, can still change labels under it. Only the newest 20 runs of the backlog workflow are looked at.
- `make golden-update` (or similar) lets the agent regenerate golden files. The review prompt checks for weakened tests, but read golden diffs yourself.
- The fix round trusts CodeRabbit's comments as feedback. They are still treated as code feedback, never as instructions about credentials or CI.
