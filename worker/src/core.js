// The Worker's logic, kept free of Cloudflare APIs so it runs under `node --test`.
// Everything that talks to the network takes `fetch` as an argument.

const MINUTE_MS = 60 * 1000;
const DAY_MS = 24 * 60 * MINUTE_MS;

// "HH:MM" (UTC) of a time given in epoch milliseconds.
export function tickTime(scheduledTime) {
  return new Date(scheduledTime).toISOString().slice(11, 16);
}

// What is due at a tick. No stored state: both lists come from the table and
// the tick's own scheduled time.
//   start  rows whose time of day equals the tick
//   check  rows started checkAfterMinutes before the tick, each with `since`,
//          the time that start was scheduled for (it may be the previous day)
export function dueAt(schedule, scheduledTime, checkAfterMinutes) {
  const now = tickTime(scheduledTime);
  const sinceMs = scheduledTime - checkAfterMinutes * MINUTE_MS;
  const earlier = tickTime(sinceMs);
  const since = new Date(sinceMs);
  return {
    time: now,
    start: schedule.filter((row) => row.at.includes(now)),
    check: schedule.filter((row) => row.at.includes(earlier)).map((row) => ({ row, since })),
  };
}

function githubHeaders(token) {
  return {
    Authorization: `Bearer ${token}`,
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
    "User-Agent": "agent-loop-trigger",
  };
}

function rowName(row) {
  return `${row.repo} ${row.workflow}`;
}

const EXPIRY_HEADER = "github-authentication-token-expiration";

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
export async function startRow(row, { fetch, token, api }) {
  const url = `${api}/repos/${row.repo}/actions/workflows/${row.workflow}/dispatches`;
  let res;
  try {
    res = await fetch(url, {
      method: "POST",
      headers: { ...githubHeaders(token), "Content-Type": "application/json" },
      body: JSON.stringify(row.body),
    });
  } catch (err) {
    return { ok: false, problem: `Could not start ${rowName(row)}: ${err.message}`, expiryHeader: null };
  }
  const expiryHeader = res.headers.get(EXPIRY_HEADER);
  if (res.status === 204) return { ok: true, problem: null, expiryHeader };
  const text = (await res.text().catch(() => "")).slice(0, 300);
  return {
    ok: false,
    problem: `Could not start ${rowName(row)}: GitHub answered ${res.status}${text ? ` ${text}` : ""}`,
    expiryHeader,
  };
}

// Check that a manually started run of the workflow was created since `since`.
// Returns { ok, problem, expiryHeader }.
export async function checkRow(row, since, { fetch, token, api }) {
  const stamp = since.toISOString().replace(/\.\d{3}Z$/, "Z");
  const query = `event=workflow_dispatch&per_page=1&created=${encodeURIComponent(`>=${stamp}`)}`;
  const url = `${api}/repos/${row.repo}/actions/workflows/${row.workflow}/runs?${query}`;
  const fail = (why, expiryHeader = null) => ({ ok: false, problem: `Could not check ${rowName(row)}: ${why}`, expiryHeader });
  let res;
  try {
    res = await fetch(url, { headers: githubHeaders(token) });
  } catch (err) {
    return fail(err.message);
  }
  const expiryHeader = res.headers.get(EXPIRY_HEADER);
  if (res.status !== 200) {
    const text = (await res.text().catch(() => "")).slice(0, 300);
    return fail(`GitHub answered ${res.status}${text ? ` ${text}` : ""}`, expiryHeader);
  }
  let data;
  try {
    data = await res.json();
  } catch {
    return fail("GitHub's answer was not JSON", expiryHeader);
  }
  if (typeof data.total_count !== "number") return fail("GitHub's answer had no run count", expiryHeader);
  if (data.total_count > 0) return { ok: true, problem: null, expiryHeader };
  return { ok: false, problem: `${rowName(row)} should have started at ${stamp}, but no run has been created since.`, expiryHeader };
}

// The token's expiry header, from a request made only to read it.
async function fetchExpiryHeader({ fetch, token, api }) {
  try {
    const res = await fetch(`${api}/rate_limit`, { headers: githubHeaders(token) });
    return res.headers.get(EXPIRY_HEADER);
  } catch {
    return null;
  }
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

// One tick: start what is due now, check what was started a few minutes ago,
// and report every problem in one Discord message. Most ticks have nothing
// due and make no request at all. No retries.
// Returns { time, started, checked, problems }.
export async function runTick({ scheduledTime, schedule, env, fetch, checkAfterMinutes, tokenCheckAt, tokenWarnDays }) {
  const due = dueAt(schedule, scheduledTime, checkAfterMinutes);
  const tokenCheck = due.time === tokenCheckAt;
  const result = { time: due.time, started: [], checked: [], problems: [] };
  if (due.start.length === 0 && due.check.length === 0 && !tokenCheck) return result;

  const gh = { fetch, token: env.GITHUB_TOKEN, api: env.GITHUB_API || "https://api.github.com" };
  if (!gh.token) {
    result.problems.push("No GITHUB_TOKEN set; nothing was started or checked.");
  } else {
    let expiryHeader = null;
    for (const row of due.start) {
      const r = await startRow(row, gh);
      if (r.ok) result.started.push(rowName(row));
      else result.problems.push(r.problem);
      expiryHeader = expiryHeader || r.expiryHeader;
    }
    for (const { row, since } of due.check) {
      const r = await checkRow(row, since, gh);
      if (r.ok) result.checked.push(rowName(row));
      else result.problems.push(r.problem);
      expiryHeader = expiryHeader || r.expiryHeader;
    }
    if (tokenCheck) {
      expiryHeader = expiryHeader || (await fetchExpiryHeader(gh));
      const warning = tokenExpiryWarning(expiryHeader, new Date(scheduledTime), tokenWarnDays);
      if (warning) result.problems.push(warning);
    }
  }

  await alertDiscord(result.problems, { fetch, webhook: env.DISCORD_WEBHOOK_URL });
  return result;
}
