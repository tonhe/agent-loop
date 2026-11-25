import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { jobs, VERIFY_WINDOW_MINUTES, TOKEN_WARN_DAYS } from "../src/config.js";
import {
  allTimes,
  alertDiscord,
  cronTimes,
  dispatchJob,
  jobsForFiring,
  normalizeCron,
  parseTokenExpiry,
  runCron,
  tokenExpiryWarning,
  verifyJob,
} from "../src/core.js";

const API = "https://api.github.test";
const HOOK = "https://discord.test/hook";
const NOW = Date.UTC(2026, 10, 26, 7, 17, 0);

// A fake fetch: answers by URL prefix and records every call.
function fakeFetch(routes) {
  const calls = [];
  const fn = async (url, init = {}) => {
    calls.push({ url, init, body: init.body ? JSON.parse(init.body) : undefined });
    for (const [match, answer] of routes) {
      if (url.includes(match)) {
        const a = typeof answer === "function" ? answer(url, init) : answer;
        if (a instanceof Error) throw a;
        return new Response(a.body ?? null, { status: a.status, headers: a.headers });
      }
    }
    throw new Error(`unexpected fetch ${url}`);
  };
  fn.calls = calls;
  return fn;
}

const devJob = { repo: "o/r", workflow: "agent-dev.yml", ref: "main", inputs: { mode: "scheduled" }, cron: "17 7 * * *", verifyCron: "27 7 * * *" };
const triageJob = { repo: "o/r", workflow: "agent-backlog.yml", ref: "main", cron: "17 6 * * *", verifyCron: "27 6 * * *", expiryAlert: true };
const testJobs = [triageJob, devJob];
const env = { GITHUB_TOKEN: "t0ken", DISCORD_WEBHOOK_URL: HOOK, GITHUB_API: API };

function run(cron, fetch, over = {}) {
  return runCron({ cron, scheduledTime: NOW, jobs: testJobs, env, fetch, verifyWindowMinutes: 12, tokenWarnDays: 14, ...over });
}

function tomlCrons() {
  const toml = readFileSync(fileURLToPath(new URL("../wrangler.toml", import.meta.url)), "utf8");
  const block = toml.match(/\[triggers\]\s*crons\s*=\s*\[([^\]]*)\]/);
  assert.ok(block, "wrangler.toml has a [triggers] crons list");
  return [...block[1].matchAll(/"([^"]+)"/g)].map((m) => m[1]);
}

test("the crons in wrangler.toml fire at exactly the times the config uses", () => {
  const fired = tomlCrons().flatMap((c) => cronTimes(c));
  assert.equal(new Set(fired).size, fired.length, "no time is fired twice");
  assert.deepEqual(fired.sort(), allTimes(jobs));
  assert.deepEqual(allTimes(jobs), ["01:43", "01:53", "06:17", "06:27", "07:17", "07:27", "13:43", "13:53"]);
});

test("wrangler.toml stays inside the free plan's five cron triggers", () => {
  assert.ok(tomlCrons().length <= 5);
});

test("every time wrangler.toml fires at starts or checks exactly one job", () => {
  for (const cron of tomlCrons()) {
    for (const time of cronTimes(cron)) {
      const at = Date.parse(`2026-11-26T${time}:00Z`);
      const { dispatch, verify } = jobsForFiring(jobs, cron, at);
      assert.equal(dispatch.length + verify.length, 1, `${time} matches one job`);
    }
  }
  const at = (t) => jobsForFiring(jobs, "17,27 6,7 * * *", Date.parse(`2026-11-26T${t}:00Z`));
  assert.equal(at("06:17").dispatch[0].workflow, "agent-backlog.yml");
  assert.equal(at("06:27").verify[0].workflow, "agent-backlog.yml");
  assert.equal(at("07:17").dispatch[0].workflow, "agent-dev.yml");
  assert.equal(at("07:27").verify[0].workflow, "agent-dev.yml");
});

test("cronTimes: lists, ranges, steps; anything but a daily cron is refused", () => {
  assert.deepEqual(cronTimes("17 6 * * *"), ["06:17"]);
  assert.deepEqual(cronTimes("43,53 1,13 * * *"), ["01:43", "01:53", "13:43", "13:53"]);
  assert.deepEqual(cronTimes("0 9-11 * * *"), ["09:00", "10:00", "11:00"]);
  assert.deepEqual(cronTimes("0 */8 * * *"), ["00:00", "08:00", "16:00"]);
  assert.deepEqual(cronTimes("*/30 5 * * *"), ["05:00", "05:30"]);
  assert.throws(() => cronTimes("0 9 * * MON"), /only daily/);
  assert.throws(() => cronTimes("0 9 1 * *"), /only daily/);
  assert.throws(() => cronTimes("0 9 * *"), /five fields/);
  assert.throws(() => cronTimes("61 9 * * *"), /out of range/);
  assert.throws(() => cronTimes("x 9 * * *"), /cannot read/);
});

test("the config: every job has what a start needs, and no cron is used twice", () => {
  const seen = new Set();
  for (const j of jobs) {
    assert.match(j.repo, /^[\w.-]+\/[\w.-]+$/);
    assert.match(j.workflow, /^[\w.-]+\.ya?ml$/);
    for (const c of [j.cron, j.verifyCron]) {
      assert.equal(normalizeCron(c).split(" ").length, 5, `${c} has five fields`);
      assert.ok(!seen.has(normalizeCron(c)), `${c} is used once`);
      seen.add(normalizeCron(c));
    }
  }
  assert.ok(VERIFY_WINDOW_MINUTES >= 10);
  assert.equal(TOKEN_WARN_DAYS, 14);
});

test("the config: the dev job asks for the nightly selection, after triage", () => {
  const dev = jobs.find((j) => j.workflow === "agent-dev.yml");
  const triage = jobs.find((j) => j.workflow === "agent-backlog.yml");
  assert.deepEqual(dev.inputs, { mode: "scheduled" });
  assert.equal(triage.cron, "17 6 * * *");
  assert.equal(dev.cron, "17 7 * * *");
  assert.equal(jobs.find((j) => j.workflow === "agent-followup.yml").cron, "43 1,13 * * *");
  assert.equal(jobs.filter((j) => j.expiryAlert).length, 1);
});

test("jobsForFiring: a job's own cron text names that job whatever the time", () => {
  const noon = Date.UTC(2026, 10, 26, 12, 0, 0);
  assert.deepEqual(jobsForFiring(testJobs, "17 7 * * *", noon), { dispatch: [devJob], verify: [] });
  assert.deepEqual(jobsForFiring(testJobs, " 27  7 * * * ", noon), { dispatch: [], verify: [devJob] });
});

test("jobsForFiring: a merged cron is matched by the time it fired at", () => {
  const merged = "17,27 6,7 * * *";
  const at = (h, m) => Date.UTC(2026, 10, 26, h, m, 0);
  assert.deepEqual(jobsForFiring(testJobs, merged, at(6, 17)), { dispatch: [triageJob], verify: [] });
  assert.deepEqual(jobsForFiring(testJobs, merged, at(6, 27)), { dispatch: [], verify: [triageJob] });
  assert.deepEqual(jobsForFiring(testJobs, merged, at(7, 17)), { dispatch: [devJob], verify: [] });
  assert.deepEqual(jobsForFiring(testJobs, merged, at(7, 27)), { dispatch: [], verify: [devJob] });
  assert.deepEqual(jobsForFiring(testJobs, merged, at(8, 17)), { dispatch: [], verify: [] });
});

test("runCron: a merged cron starts the job due at that time", async () => {
  const f = fakeFetch([["/dispatches", { status: 204 }]]);
  const r = await run("17,27 6,7 * * *", f);
  assert.deepEqual(r, { started: ["o/r agent-dev.yml"], checked: [], problems: [] });
});

test("dispatchJob: posts ref and inputs with the token, 204 is success", async () => {
  const f = fakeFetch([["/dispatches", { status: 204, headers: { "github-authentication-token-expiration": "2027-01-01 00:00:00 UTC" } }]]);
  const r = await dispatchJob(devJob, { fetch: f, token: "t0ken", api: API });
  assert.deepEqual(r, { ok: true, problem: null, expiryHeader: "2027-01-01 00:00:00 UTC" });
  const c = f.calls[0];
  assert.equal(c.url, `${API}/repos/o/r/actions/workflows/agent-dev.yml/dispatches`);
  assert.equal(c.init.method, "POST");
  assert.equal(c.init.headers.Authorization, "Bearer t0ken");
  assert.ok(c.init.headers["User-Agent"]);
  assert.deepEqual(c.body, { ref: "main", inputs: { mode: "scheduled" } });
});

test("dispatchJob: a job without inputs sends only the ref", async () => {
  const f = fakeFetch([["/dispatches", { status: 204 }]]);
  await dispatchJob(triageJob, { fetch: f, token: "t", api: API });
  assert.deepEqual(f.calls[0].body, { ref: "main" });
});

test("dispatchJob: anything but 204 is a problem that names the workflow and status", async () => {
  for (const status of [200, 401, 404, 422, 500]) {
    const f = fakeFetch([["/dispatches", { status, body: status === 200 ? "{}" : '{"message":"nope"}' }]]);
    const r = await dispatchJob(devJob, { fetch: f, token: "t", api: API });
    assert.equal(r.ok, false, `status ${status}`);
    assert.match(r.problem, new RegExp(`o/r agent-dev\\.yml: GitHub answered ${status}`));
  }
});

test("dispatchJob: a network error is a problem, not a throw", async () => {
  const f = fakeFetch([["/dispatches", new Error("connection reset")]]);
  const r = await dispatchJob(devJob, { fetch: f, token: "t", api: API });
  assert.equal(r.ok, false);
  assert.match(r.problem, /connection reset/);
});

test("verifyJob: asks for manually started runs since the given time", async () => {
  const f = fakeFetch([["/runs", { status: 200, body: '{"total_count":1,"workflow_runs":[{}]}' }]]);
  const r = await verifyJob(devJob, new Date(Date.UTC(2026, 10, 26, 7, 15, 0)), { fetch: f, token: "t0ken", api: API });
  assert.deepEqual(r, { ok: true, problem: null });
  const u = new URL(f.calls[0].url);
  assert.equal(u.pathname, "/repos/o/r/actions/workflows/agent-dev.yml/runs");
  assert.equal(u.searchParams.get("event"), "workflow_dispatch");
  assert.equal(u.searchParams.get("created"), ">=2026-11-26T07:15:00Z");
  assert.equal(f.calls[0].init.headers.Authorization, "Bearer t0ken");
});

test("verifyJob: no run since then is a problem", async () => {
  const f = fakeFetch([["/runs", { status: 200, body: '{"total_count":0,"workflow_runs":[]}' }]]);
  const r = await verifyJob(devJob, new Date(NOW), { fetch: f, token: "t", api: API });
  assert.equal(r.ok, false);
  assert.match(r.problem, /o\/r agent-dev\.yml was started but no run exists since 2026-11-26T07:17:00Z/);
});

test("verifyJob: a failed or unreadable answer is a problem, never a pass", async () => {
  const cases = [
    { status: 403, body: '{"message":"forbidden"}' },
    { status: 200, body: "not json" },
    { status: 200, body: "{}" },
    new Error("timeout"),
  ];
  for (const answer of cases) {
    const f = fakeFetch([["/runs", answer]]);
    const r = await verifyJob(devJob, new Date(NOW), { fetch: f, token: "t", api: API });
    assert.equal(r.ok, false);
    assert.match(r.problem, /Could not check o\/r agent-dev\.yml/);
  }
});

test("parseTokenExpiry: GitHub's formats, and nothing for junk", () => {
  assert.equal(parseTokenExpiry("2026-12-25 09:00:00 UTC").toISOString(), "2026-12-25T09:00:00.000Z");
  assert.equal(parseTokenExpiry("2026-12-25 09:00:00 -0500").toISOString(), "2026-12-25T14:00:00.000Z");
  assert.equal(parseTokenExpiry("2026-12-25 09:00:00 +01:00").toISOString(), "2026-12-25T08:00:00.000Z");
  assert.equal(parseTokenExpiry(null), null);
  assert.equal(parseTokenExpiry(""), null);
  assert.equal(parseTokenExpiry("soon"), null);
});

test("tokenExpiryWarning: warns under 14 days, silent at 14 or with no header", () => {
  const now = new Date(NOW);
  const at = (ms) => new Date(NOW + ms).toISOString().replace("T", " ").replace(/\.\d{3}Z$/, " UTC");
  const day = 24 * 60 * 60 * 1000;
  assert.equal(tokenExpiryWarning(null, now, 14), null);
  assert.equal(tokenExpiryWarning(at(14 * day), now, 14), null);
  assert.equal(tokenExpiryWarning(at(30 * day), now, 14), null);
  assert.match(tokenExpiryWarning(at(14 * day - 1000), now, 14), /expires on 2026-12-10 \(13 days left\)/);
  assert.match(tokenExpiryWarning(at(1.5 * day), now, 14), /\(1 day left\)/);
  assert.match(tokenExpiryWarning(at(-day), now, 14), /expired on 2026-11-25/);
});

test("alertDiscord: nothing to say, nothing sent", async () => {
  const f = fakeFetch([]);
  await alertDiscord([], { fetch: f, webhook: HOOK });
  assert.equal(f.calls.length, 0);
});

test("alertDiscord: one message with every problem; a refusal throws", async () => {
  const f = fakeFetch([[HOOK, { status: 204 }]]);
  await alertDiscord(["first", "second"], { fetch: f, webhook: HOOK });
  assert.equal(f.calls.length, 1);
  assert.match(f.calls[0].body.content, /- first\n- second/);
  const bad = fakeFetch([[HOOK, { status: 404 }]]);
  await assert.rejects(alertDiscord(["first"], { fetch: bad, webhook: HOOK }), /Discord answered 404.*first/);
  await assert.rejects(alertDiscord(["first"], { fetch: f, webhook: undefined }), /No DISCORD_WEBHOOK_URL.*first/);
});

test("runCron: the start cron starts its job and stays quiet on 204", async () => {
  const f = fakeFetch([["/dispatches", { status: 204 }]]);
  const r = await run("17 7 * * *", f);
  assert.deepEqual(r, { started: ["o/r agent-dev.yml"], checked: [], problems: [] });
  assert.equal(f.calls.length, 1);
  assert.match(f.calls[0].url, /agent-dev\.yml\/dispatches$/);
});

test("runCron: a refused start goes to Discord", async () => {
  const f = fakeFetch([["/dispatches", { status: 401, body: '{"message":"Bad credentials"}' }], [HOOK, { status: 204 }]]);
  const r = await run("17 7 * * *", f);
  assert.deepEqual(r.started, []);
  assert.equal(r.problems.length, 1);
  const hook = f.calls.find((c) => c.url === HOOK);
  assert.match(hook.body.content, /Could not start o\/r agent-dev\.yml: GitHub answered 401/);
  assert.doesNotMatch(hook.body.content, /t0ken/);
});

test("runCron: the check cron looks back over the window and alerts when no run exists", async () => {
  const f = fakeFetch([["/runs", { status: 200, body: '{"total_count":0}' }], [HOOK, { status: 204 }]]);
  const r = await run("27 7 * * *", f);
  assert.deepEqual(r.checked, []);
  const u = new URL(f.calls[0].url);
  assert.equal(u.searchParams.get("created"), ">=2026-11-26T07:05:00Z");
  assert.match(f.calls.find((c) => c.url === HOOK).body.content, /no run exists/);
});

test("runCron: the check cron is quiet when the run exists", async () => {
  const f = fakeFetch([["/runs", { status: 200, body: '{"total_count":1}' }]]);
  const r = await run("27 7 * * *", f);
  assert.deepEqual(r, { started: [], checked: ["o/r agent-dev.yml"], problems: [] });
  assert.equal(f.calls.length, 1);
});

test("runCron: the token warning comes only from the job marked for it", async () => {
  const soon = { "github-authentication-token-expiration": "2026-12-01 00:00:00 UTC" };
  const f = fakeFetch([["/dispatches", { status: 204, headers: soon }], [HOOK, { status: 204 }]]);
  const dev = await run("17 7 * * *", f);
  assert.deepEqual(dev.problems, []);
  const triage = await run("17 6 * * *", f);
  assert.deepEqual(triage.started, ["o/r agent-backlog.yml"]);
  assert.equal(triage.problems.length, 1);
  assert.match(triage.problems[0], /token expires on 2026-12-01 \(4 days left\)/);
});

test("runCron: a cron that matches no job is reported", async () => {
  const f = fakeFetch([[HOOK, { status: 204 }]]);
  const r = await run("5 5 * * *", f, { scheduledTime: Date.UTC(2026, 10, 26, 5, 5, 0) });
  assert.match(r.problems[0], /Cron "5 5 \* \* \*" at 05:05 UTC matches no job/);
  assert.equal(f.calls.length, 1);
});

test("runCron: a missing token is reported and nothing is sent to GitHub", async () => {
  const f = fakeFetch([[HOOK, { status: 204 }]]);
  const r = await run("17 7 * * *", f, { env: { DISCORD_WEBHOOK_URL: HOOK, GITHUB_API: API } });
  assert.match(r.problems[0], /No GITHUB_TOKEN/);
  assert.deepEqual(f.calls.map((c) => c.url), [HOOK]);
});

test("runCron: the real GitHub address is the default", async () => {
  const f = fakeFetch([["https://api.github.com/repos/o/r/actions/workflows/agent-dev.yml/dispatches", { status: 204 }]]);
  const r = await run("17 7 * * *", f, { env: { GITHUB_TOKEN: "t", DISCORD_WEBHOOK_URL: HOOK } });
  assert.deepEqual(r.started, ["o/r agent-dev.yml"]);
});
