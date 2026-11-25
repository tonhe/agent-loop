// What the Worker starts, and when. All cron times are UTC.
//
// Each job has two crons:
//   cron        when the workflow is started
//   verifyCron  about 10 minutes later: checks that a run was really created
// Only daily crons work here (minute and hour fields; the other three "*").
// The crons under [triggers] in wrangler.toml must fire at exactly these times;
// they are merged there to stay inside Cloudflare's limit (a test checks this).
//
// expiryAlert: this job's start also warns when the GitHub token is close to
// expiring. Set it on one daily job per token so the warning arrives once a day.

export const VERIFY_WINDOW_MINUTES = 12; // how far back the check looks for the run
export const TOKEN_WARN_DAYS = 14;

export const jobs = [
  {
    repo: "tonhe/viaduct",
    workflow: "agent-backlog.yml",
    ref: "main",
    cron: "17 6 * * *", // ~1:17 AM Eastern (2:17 AM in summer)
    verifyCron: "27 6 * * *",
    expiryAlert: true,
  },
  {
    repo: "tonhe/viaduct",
    workflow: "agent-dev.yml",
    ref: "main",
    inputs: { mode: "scheduled" },
    cron: "17 7 * * *", // ~2:17 AM Eastern, an hour after triage
    verifyCron: "27 7 * * *",
  },
  {
    repo: "tonhe/viaduct",
    workflow: "agent-followup.yml",
    ref: "main",
    cron: "43 1,13 * * *", // sweep of every agent PR, twice a day
    verifyCron: "53 1,13 * * *",
  },
];
