# agent-loop trigger (Cloudflare Worker)

Starts the agent-loop workflows on a schedule from outside GitHub.

GitHub's own `schedule:` trigger is best effort: on a repo it can start runs many hours late or skip them. This Worker runs on Cloudflare's cron and starts each workflow through the GitHub API, the same way `gh workflow run` does. The caller workflows need a `workflow_dispatch` trigger and no `schedule:` block (see `examples/caller/`).

## How it works

The Worker has one cron trigger, `7-59/10 * * * *`: a tick at :07, :17, :27, :37, :47 and :57 of every hour. (Cloudflare's free plan allows five cron triggers per account; this uses one.)

What happens at which tick is a table in `src/config.js`. Times are UTC:

| Time | Start | Body sent to GitHub |
|---|---|---|
| 06:17 | `agent-backlog.yml` | `{"ref":"main"}` |
| 07:17 | `agent-dev.yml` | `{"ref":"main","inputs":{"mode":"scheduled"}}` |
| 01:47 and 13:47 | `agent-followup.yml` | `{"ref":"main"}` |

On every tick the Worker takes the time from the tick itself (the event's `scheduledTime`, not the clock) and:

1. Starts every row whose time equals the tick. Most ticks start nothing and make no request.
2. Posts to Discord if GitHub does not answer a start with 204.
3. Checks every row that was due 10 minutes earlier: it lists that workflow's manually started runs created since the start time, and posts to Discord if there are none. So the checks happen at 06:27, 07:27, 01:57 and 13:57. Nothing is stored between ticks; the check is worked out from the same table.
4. On the 06:17 tick, reads the `github-authentication-token-expiration` header from GitHub's response and posts to Discord if the token has fewer than 14 days left.

There are no retries. If a tick is skipped, the next tick's check finds no run and alerts.

A night with no message means everything started. If Discord itself refuses a message, the invocation fails and shows as an error in the Worker's logs in the Cloudflare dashboard.

The Eastern times move by an hour with daylight saving: triage and dev are 1:17 and 2:17 AM in winter, 2:17 and 3:17 AM in summer.

## Files

- `src/config.js`: the schedule table. Each row names its repo, so another repo is more rows. Every time must end in 7 (a tick).
- `wrangler.toml`: the Worker's settings and its one trigger.
- `src/core.js`: the logic. `src/index.js`: the Cloudflare entry point.
- `test/`: `npm test` (Node 20 or later, no dependencies, no network).
- `tick.sh`: fires one tick of a locally running Worker, for testing.

## Setup

You need a Cloudflare account, Node, and the GitHub account that owns the repo.

### 1. Create the GitHub token

GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token.

- Resource owner: `tonhe`.
- Expiration: custom, one year from today (the longest allowed).
- Repository access: "Only select repositories" → `tonhe/viaduct` only.
- Repository permissions: "Actions" → "Read and write". Nothing else. GitHub adds "Metadata: Read-only" by itself; leave it.

Copy the token (`github_pat_...`); it is shown once.

This token can start, cancel and re-run workflows and read their runs and logs in that one repo. It cannot read or change code, issues or secrets.

### 2. Get the Discord webhook URL

Use the webhook the loop already posts to (the repo's `DISCORD_WEBHOOK_URL` secret), or make another: channel settings → Integrations → Webhooks → New Webhook → Copy Webhook URL.

### 3. Test locally, one entry at a time

This runs the Worker on your machine with the real token, so every start below creates a real workflow run.

In this directory, create a file named `.dev.vars` (it is in `.gitignore`):

```
GITHUB_TOKEN=github_pat_...
DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/...
```

Terminal 1:

```sh
npm test
npx wrangler dev --test-scheduled
```

Terminal 2, once terminal 1 says `Ready on http://localhost:8787`. Each line fires one tick; a start, then its check:

```sh
./tick.sh 06:17    # starts agent-backlog (and reads the token's expiry)
./tick.sh 06:27    # checks it

./tick.sh 01:47    # starts agent-followup
./tick.sh 01:57    # checks it

./tick.sh 07:17    # starts agent-dev, mode=scheduled
./tick.sh 07:27    # checks it
```

`tick.sh` gives the tick the most recent moment that time of day occurred, so a check looks back from a real time. Each call answers `{"outcome":"ok","noRetry":false}`, and terminal 1 prints what the tick did, for example:

```
{"time":"06:17","started":["tonhe/viaduct agent-backlog.yml"],"checked":[],"problems":[]}
{"time":"06:27","started":[],"checked":["tonhe/viaduct agent-backlog.yml"],"problems":[]}
```

A start must list the workflow under `started`, its check under `checked`, and `problems` must be empty. Anything in `problems` is also posted to Discord.

Two things to know:

- The dev start is the real nightly run: it selects and works up to `max_issues` ready issues. Do it last, when you want that to happen.
- A local check can pass on an older run, because it counts every manually started run since that time of day last occurred. So also confirm on GitHub that each workflow has a run created in the last few minutes:

```sh
gh run list -R tonhe/viaduct --event workflow_dispatch --limit 6
```

To see an alert arrive in Discord, fire a tick that checks something not started: `./tick.sh 13:57` alerts if no follow-up run was created since the last 13:47 UTC.

When done, stop terminal 1 with Ctrl-C and delete `.dev.vars`.

### 4. Deploy

```sh
npx wrangler login
npx wrangler deploy
npx wrangler secret put GITHUB_TOKEN
npx wrangler secret put DISCORD_WEBHOOK_URL
```

`wrangler secret put` asks for the value and stores it encrypted; it is never written to a file. Deploy first: a secret needs the Worker to exist.

`wrangler deploy` should print the schedule `7-59/10 * * * *`. The Worker has no web address (`workers_dev = false`); it only runs on its cron.

### 5. The first night

The deployed Worker is proven by its first real ticks: no Discord message, and new runs at 06:17 and 07:17 UTC:

```sh
gh run list -R tonhe/viaduct --event workflow_dispatch --limit 6
```

The Worker's own log (Cloudflare dashboard → Workers → `agent-loop-trigger` → Logs) has one line for each tick that did something.

## Renewing the token

When the warning arrives, create a new token as in step 1 and run `npx wrangler secret put GITHUB_TOKEN` again. Nothing else changes.

## Changing the schedule or adding a repo

Edit the table in `src/config.js`, run `npm test`, and `npx wrangler deploy`. Times must end in 7. For another repo, add rows naming it and give the token access to that repo too. `wrangler.toml` does not change.
