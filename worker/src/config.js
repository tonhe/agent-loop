// What the Worker starts, and when. Edit the table; the code does not change.
//
// The Worker has ONE cron trigger (wrangler.toml): "7-59/10 * * * *", a tick at
// :07, :17, :27, :37, :47 and :57 of every hour. On each tick it starts every
// row whose time equals the tick, and checks every row started 10 minutes
// earlier. So every time below must end in 7, and all times are UTC.

export const TRIGGER = "7-59/10 * * * *";

// The "did it start" check runs this long after each start. It must be a
// multiple of the tick spacing (10 minutes).
export const CHECK_AFTER_MINUTES = 10;

// Once a day, on this tick, the GitHub token's expiry is read from a response
// header, and a warning is sent if fewer than TOKEN_WARN_DAYS remain.
export const TOKEN_CHECK_AT = "06:17";
export const TOKEN_WARN_DAYS = 14;

// One row per workflow start. `at` lists the times of day (UTC, "HH:MM").
// `body` is sent to GitHub as it is. Another repo is just more rows (and a
// token that covers it).
export const schedule = [
  // Triage, ~1:17 AM Eastern (2:17 AM in summer).
  { at: ["06:17"], repo: "tonhe/viaduct", workflow: "agent-backlog.yml", body: { ref: "main" } },
  // Dev, the nightly selection, an hour after triage.
  { at: ["07:17"], repo: "tonhe/viaduct", workflow: "agent-dev.yml", body: { ref: "main", inputs: { mode: "scheduled" } } },
  // Follow-up sweep of every agent PR, twice a day.
  { at: ["01:47", "13:47"], repo: "tonhe/viaduct", workflow: "agent-followup.yml", body: { ref: "main" } },
];

// The sprint switch is the Worker variable SPRINT (wrangler.toml [vars]). Only
// the exact value "on" turns it on; then these rows run IN ADDITION to the
// table above. Anything else ("off", missing, a typo) is off, and the nightly
// table runs alone.
//
// Same rules as above: every time ends in 7, and each start is checked 10
// minutes later. No time repeats a nightly time of the same workflow, so the
// nightly starts stay the only ones at 06:17 and 07:17.
//   Dev every 2 hours, on the odd hours. 07:17 is the nightly dev start, so
//   with the switch on dev starts 12 times a day, 2 hours apart.
//   Triage every 6 hours. 06:17 is the nightly triage start, so with the
//   switch on triage starts 4 times a day, each an hour before a dev start
//   (00:17 before 01:17, 12:17 before 13:17, 18:17 before 19:17), as at night.
// Follow-up does not change.
export const sprintSchedule = [
  { at: ["00:17", "12:17", "18:17"], repo: "tonhe/viaduct", workflow: "agent-backlog.yml", body: { ref: "main" } },
  {
    at: ["01:17", "03:17", "05:17", "09:17", "11:17", "13:17", "15:17", "17:17", "19:17", "21:17", "23:17"],
    repo: "tonhe/viaduct",
    workflow: "agent-dev.yml",
    body: { ref: "main", inputs: { mode: "scheduled" } },
  },
];
