// The Worker's logic, kept free of Cloudflare APIs so it runs under `node --test`.
// Everything that talks to the network takes `fetch` as an argument.

const DAY_MS = 24 * 60 * 60 * 1000;

export function normalizeCron(cron) {
  return String(cron).trim().split(/\s+/).join(" ");
}

// One minute or hour field: "*", "5", "1,13", "1-5", "*/15". Returns the values.
function expandField(field, min, max) {
  const out = new Set();
  for (const part of field.split(",")) {
    const m = part.match(/^(\*|\d+(?:-\d+)?)(?:\/(\d+))?$/);
    if (!m) throw new Error(`cannot read cron field "${field}"`);
    let lo = min;
    let hi = max;
    if (m[1] !== "*") {
      const [a, b] = m[1].split("-").map(Number);
      lo = a;
      hi = b === undefined ? (m[2] ? max : a) : b;
    }
    const step = m[2] ? Number(m[2]) : 1;
    if (lo < min || hi > max || lo > hi || step < 1) throw new Error(`cron field "${field}" is out of range`);
    for (let v = lo; v <= hi; v += step) out.add(v);
  }
  return out;
}

// The "HH:MM" times of day (UTC) a daily cron fires at. Only daily crons are
// supported: day-of-month, month and day-of-week must be "*".
export function cronTimes(cron) {
  const f = normalizeCron(cron).split(" ");
  if (f.length !== 5) throw new Error(`cron "${cron}" must have five fields`);
  if (f[2] !== "*" || f[3] !== "*" || f[4] !== "*") throw new Error(`cron "${cron}": only daily crons are supported`);
  const times = [];
  for (const h of expandField(f[1], 0, 23)) {
    for (const m of expandField(f[0], 0, 59)) {
      times.push(`${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}`);
    }
  }
  return times.sort();
}

function firesAt(cron, time) {
  return cronTimes(cron).includes(time);
}

// Which jobs a cron firing starts, and which it checks.
//
// Cloudflare's free plan allows five cron triggers per account, so
// wrangler.toml merges the jobs' crons into fewer triggers. A firing is
// therefore matched by its scheduled time of day (UTC). A firing whose cron
// text is exactly one job's cron or verifyCron names that job directly,
// whatever the time: that is how a single job is fired in a local test.
export function jobsForFiring(jobs, cron, scheduledTime) {
  const c = normalizeCron(cron);
  const exact = {
    dispatch: jobs.filter((j) => normalizeCron(j.cron) === c),
    verify: jobs.filter((j) => normalizeCron(j.verifyCron) === c),
  };
  if (exact.dispatch.length > 0 || exact.verify.length > 0) return exact;
  const time = new Date(scheduledTime).toISOString().slice(11, 16);
  return {
    dispatch: jobs.filter((j) => firesAt(j.cron, time)),
    verify: jobs.filter((j) => firesAt(j.verifyCron, time)),
  };
}

// Every time of day (UTC, "HH:MM") at which some job starts or is checked.
// The crons in wrangler.toml must fire at exactly these times.
export function allTimes(jobs) {
  return [...new Set(jobs.flatMap((j) => [...cronTimes(j.cron), ...cronTimes(j.verifyCron)]))].sort();
}

function githubHeaders(token) {
  return {
    Authorization: `Bearer ${token}`,
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
    "User-Agent": "agent-loop-trigger",
  };
}

function jobName(job) {
  return `${job.repo} ${job.workflow}`;
}

// GitHub sends "2026-12-25 09:00:00 UTC" (or with a numeric offset).
// Returns a Date, or null when the header is absent or unreadable.
export function parseTokenExpiry(header) {
  if (!header) return null;
  const m = String(header).trim().match(/^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2})\s*(UTC|Z|[+-]\d{2}:?\d{2})?$/);
  if (!m) return null;
  let zone = m[3] || "Z";
  if (zone === "UTC") zone = "Z";
  if (/^[+-]\d{4}$/.test(zone)) zone = `${zone.slice(0, 3)}:${zone.slice(3)}`;
  const d = new Date(`${m[1]}T${m[2]}${zone}`);
  return Number.isNaN(d.getTime()) ? null : d;
}

// A warning line when the token expires within warnDays, otherwise null.
export function tokenExpiryWarning(header, now, warnDays) {
  const expires = parseTokenExpiry(header);
  if (!expires) return null;
  const left = expires.getTime() - now.getTime();
  if (left >= warnDays * DAY_MS) return null;
  const day = expires.toISOString().slice(0, 10);
  if (left <= 0) return `The GitHub token expired on ${day}. Create a new one and run \`wrangler secret put GITHUB_TOKEN\`.`;
  const days = Math.floor(left / DAY_MS);
  return `The GitHub token expires on ${day} (${days} day${days === 1 ? "" : "s"} left). Create a new one and run \`wrangler secret put GITHUB_TOKEN\`.`;
}

// Start one workflow. GitHub answers 204 when it accepts the request.
// Returns { ok, problem, expiryHeader }.
export async function dispatchJob(job, { fetch, token, api }) {
  const url = `${api}/repos/${job.repo}/actions/workflows/${job.workflow}/dispatches`;
  const body = { ref: job.ref || "main" };
  if (job.inputs) body.inputs = job.inputs;
  let res;
  try {
    res = await fetch(url, {
      method: "POST",
      headers: { ...githubHeaders(token), "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
  } catch (err) {
    return { ok: false, problem: `Could not start ${jobName(job)}: ${err.message}`, expiryHeader: null };
  }
  const expiryHeader = res.headers.get("github-authentication-token-expiration");
  if (res.status === 204) return { ok: true, problem: null, expiryHeader };
  const text = (await res.text().catch(() => "")).slice(0, 300);
  return {
    ok: false,
    problem: `Could not start ${jobName(job)}: GitHub answered ${res.status}${text ? ` ${text}` : ""}`,
    expiryHeader,
  };
}

// Check that a manually started run of the workflow exists since `since`.
// Returns { ok, problem }.
export async function verifyJob(job, since, { fetch, token, api }) {
  const stamp = since.toISOString().replace(/\.\d{3}Z$/, "Z");
  const query = `event=workflow_dispatch&per_page=1&created=${encodeURIComponent(`>=${stamp}`)}`;
  const url = `${api}/repos/${job.repo}/actions/workflows/${job.workflow}/runs?${query}`;
  let res;
  try {
    res = await fetch(url, { headers: githubHeaders(token) });
  } catch (err) {
    return { ok: false, problem: `Could not check ${jobName(job)}: ${err.message}` };
  }
  if (res.status !== 200) {
    const text = (await res.text().catch(() => "")).slice(0, 300);
    return { ok: false, problem: `Could not check ${jobName(job)}: GitHub answered ${res.status}${text ? ` ${text}` : ""}` };
  }
  let data;
  try {
    data = await res.json();
  } catch {
    return { ok: false, problem: `Could not check ${jobName(job)}: GitHub's answer was not JSON` };
  }
  if (typeof data.total_count !== "number") {
    return { ok: false, problem: `Could not check ${jobName(job)}: GitHub's answer had no run count` };
  }
  if (data.total_count > 0) return { ok: true, problem: null };
  return { ok: false, problem: `${jobName(job)} was started but no run exists since ${stamp}.` };
}

// Post the problems to Discord as one message. Throws if Discord refuses it,
// so the failure is at least visible in the Worker's own logs.
export async function alertDiscord(problems, { fetch, webhook }) {
  if (problems.length === 0) return;
  if (!webhook) throw new Error(`No DISCORD_WEBHOOK_URL set; problems: ${problems.join(" | ")}`);
  const content = [`**agent-loop trigger**`, ...problems.map((p) => `- ${p}`)].join("\n").slice(0, 1900);
  const res = await fetch(webhook, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ content }),
  });
  if (!res.ok) throw new Error(`Discord answered ${res.status}; problems: ${problems.join(" | ")}`);
}

// One cron firing: start the jobs due now, check the jobs started a few
// minutes ago, and report every problem in one Discord message.
// Returns { started, checked, problems }.
export async function runCron({ cron, scheduledTime, jobs, env, fetch, verifyWindowMinutes, tokenWarnDays }) {
  const now = new Date(scheduledTime);
  const { dispatch, verify } = jobsForFiring(jobs, cron, scheduledTime);
  const api = env.GITHUB_API || "https://api.github.com";
  const token = env.GITHUB_TOKEN;
  const problems = [];
  const started = [];
  const checked = [];

  if (dispatch.length === 0 && verify.length === 0) {
    problems.push(`Cron "${cron}" at ${now.toISOString().slice(11, 16)} UTC matches no job in the config. wrangler.toml and src/config.js disagree.`);
  }
  if (!token && (dispatch.length > 0 || verify.length > 0)) {
    problems.push("No GITHUB_TOKEN set; nothing was started.");
  } else {
    for (const job of dispatch) {
      const r = await dispatchJob(job, { fetch, token, api });
      if (r.ok) started.push(jobName(job));
      else problems.push(r.problem);
      if (job.expiryAlert) {
        const warning = tokenExpiryWarning(r.expiryHeader, now, tokenWarnDays);
        if (warning) problems.push(warning);
      }
    }
    const since = new Date(now.getTime() - verifyWindowMinutes * 60 * 1000);
    for (const job of verify) {
      const r = await verifyJob(job, since, { fetch, token, api });
      if (r.ok) checked.push(jobName(job));
      else problems.push(r.problem);
    }
  }

  await alertDiscord(problems, { fetch, webhook: env.DISCORD_WEBHOOK_URL });
  return { started, checked, problems };
}
