# agent-loop trigger (Cloudflare Worker)

Starts the agent-loop workflows on a schedule from outside GitHub.

GitHub's own `schedule:` trigger is best effort: on a repo it can start runs many hours late or skip them. This Worker runs on Cloudflare's cron and starts each workflow through the GitHub API, the same way `gh workflow run` does. The caller workflows need a `workflow_dispatch` trigger and no `schedule:` block (see `examples/caller/`).

## What it does

| Time (UTC) | Action |
|---|---|
| 06:17 | start `agent-backlog.yml` |
| 06:27 | check that a triage run was created |
| 07:17 | start `agent-dev.yml` with `mode=scheduled` (the nightly selection) |
| 07:27 | check that a dev run was created |
| 01:43 and 13:43 | start `agent-followup.yml` (sweep of every agent PR) |
| 01:53 and 13:53 | check that a follow-up run was created |

Cloudflare's free plan allows five cron triggers per account. `wrangler.toml` therefore merges these eight times into two triggers (`17,27 6,7 * * *` and `43,53 1,13 * * *`), and the Worker picks the job by the time of day it fired at.

It posts to Discord when:

- GitHub does not answer a start with 204;
- the check, about 10 minutes later, finds no manually started run of that workflow created in the last 12 minutes;
- the check itself fails;
- the GitHub token expires in less than 14 days (reported once a day, with the triage start);
- a cron fires that matches no job, or the token secret is missing.

A night with no message means everything started. If Discord itself refuses the message, the invocation fails and shows as an error in the Worker's logs in the Cloudflare dashboard.

Times are UTC, so the Eastern times move by an hour with daylight saving: 1:17 and 2:17 AM in winter, 2:17 and 3:17 AM in summer.

## Files

- `src/config.js`: the list of repos, workflows and crons. Edit this to add a repo or change a time. Each job has its own `cron` (start) and `verifyCron` (check); only daily crons are supported.
- `wrangler.toml`: the Worker's settings. Its merged `crons` must fire at exactly the times the config uses; `npm test` fails if they differ.
- `src/core.js`: the logic. `src/index.js`: the Cloudflare entry point.
- `test/`: `npm test` (Node 20 or later, no dependencies, no network).

## Setup

You need a Cloudflare account, Node, and a GitHub account with admin access to the repo.

### 1. Create the GitHub token

GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token.

- Resource owner: the repo's owner.
- Repository access: "Only select repositories", and pick only the repo in `src/config.js`.
- Repository permissions: "Actions: Read and write". Nothing else. ("Metadata: Read-only" is added by GitHub and is fine.)
- Expiration: up to one year. The Worker warns 14 days before it runs out.

This token can start, cancel and re-run workflows and read their runs and logs in that one repo. It cannot read or change code, issues or secrets.

### 2. Get a Discord webhook URL

Use the same webhook as the loop's `DISCORD_WEBHOOK_URL`, or create another in the channel's settings (Integrations → Webhooks).

### 3. Deploy

From this directory:

```sh
npm test
npx wrangler login
npx wrangler deploy
npx wrangler secret put GITHUB_TOKEN
npx wrangler secret put DISCORD_WEBHOOK_URL
```

`wrangler secret put` asks for the value and stores it encrypted; it is never written to a file. Deploy first: a secret needs the Worker to exist.

The Worker has no web address (`workers_dev = false`); it only runs on its crons.

### 4. Test each cron once

This runs the Worker on your machine with the real token, so each step starts a real workflow run.

Put the two secrets in a file named `.dev.vars` in this directory. It is listed in `.gitignore`; delete it when you are done.

```
GITHUB_TOKEN=github_pat_...
DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/...
```

Start the Worker locally:

```sh
npx wrangler dev --test-scheduled
```

In a second terminal, fire each job's start, then its check. Use the job's own cron from `src/config.js` (not the merged one in `wrangler.toml`): that names the job directly, whatever the time is now. The spaces in a cron are written as `+`:

```sh
curl "http://localhost:8787/__scheduled?cron=17+6+*+*+*"       # start triage
curl "http://localhost:8787/__scheduled?cron=27+6+*+*+*"       # check it

curl "http://localhost:8787/__scheduled?cron=17+7+*+*+*"       # start dev
curl "http://localhost:8787/__scheduled?cron=27+7+*+*+*"       # check it

curl "http://localhost:8787/__scheduled?cron=43+1,13+*+*+*"    # start follow-up
curl "http://localhost:8787/__scheduled?cron=53+1,13+*+*+*"    # check it
```

Each `curl` answers `Ran scheduled event`. After each one the first terminal prints a line such as `{"cron":"17 6 * * *","started":["tonhe/viaduct agent-backlog.yml"],"checked":[],"problems":[]}`. A start should list the workflow under `started`, its check under `checked`, and `problems` should be empty.

Note on the dev start: `mode=scheduled` really selects and works up to `max_issues` ready issues. Run it when you want that to happen.

Then confirm on GitHub that a run exists for each workflow:

```sh
gh run list -R tonhe/viaduct --event workflow_dispatch --limit 5
```

To see an alert arrive, fire a check with nothing started in the last 12 minutes; Discord should get "was started but no run exists".

The deployed crons themselves are proven by the first night: no Discord message, and three new runs in the list above.

## Renewing the token

When the warning arrives, create a new token as in step 1 and run `npx wrangler secret put GITHUB_TOKEN` again. Nothing else changes.

## Adding a repo

Add its jobs to `src/config.js`, make the crons in `wrangler.toml` fire at the new times as well, give the token access to that repo, run `npm test`, and deploy. Two jobs may share a time. Keep `wrangler.toml` at five crons or fewer on the free plan (the limit is per account, across all your Workers); a test checks this.
