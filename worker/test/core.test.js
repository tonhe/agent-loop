import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { schedule, TRIGGER, CHECK_AFTER_MINUTES, TOKEN_CHECK_AT, TOKEN_WARN_DAYS } from "../src/config.js";
import { alertDiscord, checkRow, dueAt, parseTokenExpiry, runTick, startRow, tickTime, tokenExpiryWarning } from "../src/core.js";

const API = "https://api.github.test";
const HOOK = "https://discord.test/hook";
const utc = (h, m, day = 26) => Date.UTC(2026, 10, day, h, m, 0);

// A fake fetch: answers by URL fragment and records every call.
function fakeFetch(routes) {
  const calls = [];
  const fn = async (url, init = {}) => {
    calls.push({ url, init, body: init.body ? JSON.parse(init.body) : undefined });
    for (const [match, answer] of routes) {
      if (url.includes(match)) {
        if (answer instanceof Error) throw answer;
        return new Response(answer.body ?? null, { status: answer.status, headers: answer.headers });
      }
    }
    throw new Error(`unexpected fetch ${url}`);
  };
  fn.calls = calls;
  return fn;
}

const triage = { at: ["06:17"], repo: "o/r", workflow: "agent-backlog.yml", body: { ref: "main" } };
const dev = { at: ["07:17"], repo: "o/r", workflow: "agent-dev.yml", body: { ref: "main", inputs: { mode: "scheduled" } } };
const sweep = { at: ["01:47", "13:47"], repo: "o/r", workflow: "agent-followup.yml", body: { ref: "main" } };
const late = { at: ["23:57"], repo: "o/two", workflow: "nightly.yml", body: { ref: "main" } };
const table = [triage, dev, sweep, late];
const env = { GITHUB_TOKEN: "t0ken", DISCORD_WEBHOOK_URL: HOOK, GITHUB_API: API };

function tick(scheduledTime, fetch, over = {}) {
  return runTick({ scheduledTime, schedule: table, env, fetch, checkAfterMinutes: 10, tokenCheckAt: "06:17", tokenWarnDays: 14, ...over });
}

// ---- what is due at a tick ----

test("dueAt: a row starts on the tick equal to its time", () => {
  assert.deepEqual(dueAt(table, utc(6, 17), 10), { time: "06:17", start: [triage], check: [] });
  assert.deepEqual(dueAt(table, utc(7, 17), 10), { time: "07:17", start: [dev], check: [] });
});

test("dueAt: a row with two times starts on both", () => {
  assert.deepEqual(dueAt(table, utc(1, 47), 10).start, [sweep]);
  assert.deepEqual(dueAt(table, utc(13, 47), 10).start, [sweep]);
});

test("dueAt: the tick 10 minutes after a start checks it, since the start's time", () => {
  assert.deepEqual(dueAt(table, utc(6, 27), 10), { time: "06:27", start: [], check: [{ row: triage, since: new Date(utc(6, 17)) }] });
  assert.deepEqual(dueAt(table, utc(7, 27), 10).check, [{ row: dev, since: new Date(utc(7, 17)) }]);
  assert.deepEqual(dueAt(table, utc(1, 57), 10).check, [{ row: sweep, since: new Date(utc(1, 47)) }]);
  assert.deepEqual(dueAt(table, utc(13, 57), 10).check, [{ row: sweep, since: new Date(utc(13, 47)) }]);
});

test("dueAt: most ticks have nothing due", () => {
  for (const [h, m] of [[0, 17], [6, 7], [6, 37], [7, 7], [7, 37], [12, 17], [13, 37], [14, 7]]) {
    const due = dueAt(table, utc(h, m), 10);
    assert.deepEqual([due.start, due.check], [[], []], `${h}:${m}`);
  }
});

test("dueAt: a start at 23:57 is checked on the 00:07 tick of the next day", () => {
  assert.deepEqual(dueAt(table, utc(23, 57, 26), 10), { time: "23:57", start: [late], check: [] });
  assert.deepEqual(dueAt(table, utc(0, 7, 27), 10), { time: "00:07", start: [], check: [{ row: late, since: new Date(utc(23, 57, 26)) }] });
});

test("dueAt: a start at 00:07 runs on the midnight-hour tick and is checked at 00:17", () => {
  const first = { at: ["00:07"], repo: "o/r", workflow: "x.yml", body: { ref: "main" } };
  assert.deepEqual(dueAt([first], utc(0, 7, 27), 10), { time: "00:07", start: [first], check: [] });
  assert.deepEqual(dueAt([first], utc(0, 17, 27), 10).check, [{ row: first, since: new Date(utc(0, 7, 27)) }]);
  assert.deepEqual(dueAt([first], utc(23, 57, 26), 10), { time: "23:57", start: [], check: [] });
});

test("dueAt: one tick can start one row and check another", () => {
  const a = { at: ["06:17"], repo: "o/r", workflow: "a.yml", body: {} };
  const b = { at: ["06:27"], repo: "o/r", workflow: "b.yml", body: {} };
  assert.deepEqual(dueAt([a, b], utc(6, 27), 10), { time: "06:27", start: [b], check: [{ row: a, since: new Date(utc(6, 17)) }] });
});

test("dueAt: the time comes from the tick, seconds and all, not from the clock", () => {
  assert.equal(tickTime(Date.UTC(2026, 10, 26, 6, 17, 42)), "06:17");
  assert.deepEqual(dueAt(table, Date.UTC(2031, 0, 1, 6, 17, 0), 10).start, [triage]);
});

// ---- the real table and wrangler.toml ----

test("config: the table is the agreed schedule", () => {
  const rows = schedule.map((r) => [r.at.join(","), r.repo, r.workflow, JSON.stringify(r.body)]);
  assert.deepEqual(rows, [
    ["06:17", "tonhe/viaduct", "agent-backlog.yml", '{"ref":"main"}'],
    ["07:17", "tonhe/viaduct", "agent-dev.yml", '{"ref":"main","inputs":{"mode":"scheduled"}}'],
    ["01:47,13:47", "tonhe/viaduct", "agent-followup.yml", '{"ref":"main"}'],
  ]);
  assert.equal(CHECK_AFTER_MINUTES, 10);
  assert.equal(TOKEN_CHECK_AT, "06:17");
  assert.equal(TOKEN_WARN_DAYS, 14);
});

test("config: every time is one the trigger fires at, so no row is silently never run", () => {
  assert.equal(TRIGGER, "7-59/10 * * * *");
  for (const row of schedule) {
    assert.match(row.repo, /^[\w.-]+\/[\w.-]+$/);
    assert.match(row.workflow, /^[\w.-]+\.ya?ml$/);
    assert.equal(typeof row.body.ref, "string");
    for (const at of row.at) assert.match(at, /^([01]\d|2[0-3]):[0-5]7$/, `${at} is HH:M7`);
  }
  assert.match(TOKEN_CHECK_AT, /^([01]\d|2[0-3]):[0-5]7$/);
  assert.equal(CHECK_AFTER_MINUTES % 10, 0);
});

test("config: over a whole day every row is started and checked once per listed time", () => {
  const started = [];
  const checked = [];
  for (let h = 0; h < 24; h++) {
    for (let m = 7; m < 60; m += 10) {
      const due = dueAt(schedule, utc(h, m), CHECK_AFTER_MINUTES);
      for (const r of due.start) started.push(`${due.time} ${r.workflow}`);
      for (const c of due.check) checked.push(`${due.time} ${c.row.workflow}`);
    }
  }
  assert.deepEqual(started, ["01:47 agent-followup.yml", "06:17 agent-backlog.yml", "07:17 agent-dev.yml", "13:47 agent-followup.yml"]);
  assert.deepEqual(checked, ["01:57 agent-followup.yml", "06:27 agent-backlog.yml", "07:27 agent-dev.yml", "13:57 agent-followup.yml"]);
});

test("wrangler.toml has exactly the one trigger the config names", () => {
  const toml = readFileSync(fileURLToPath(new URL("../wrangler.toml", import.meta.url)), "utf8");
  const block = toml.match(/\[triggers\]\s*crons\s*=\s*\[([^\]]*)\]/);
  assert.ok(block, "wrangler.toml has a [triggers] crons list");
  assert.deepEqual([...block[1].matchAll(/"([^"]+)"/g)].map((m) => m[1]), [TRIGGER]);
  assert.match(toml, /^workers_dev = false$/m);
});

// ---- talking to GitHub ----

test("startRow: posts the row's body with the token; 204 is success", async () => {
  const f = fakeFetch([["/dispatches", { status: 204, headers: { "github-authentication-token-expiration": "2027-01-01 00:00:00 UTC" } }]]);
  const r = await startRow(dev, { fetch: f, token: "t0ken", api: API });
  assert.deepEqual(r, { ok: true, problem: null, expiryHeader: "2027-01-01 00:00:00 UTC" });
  const c = f.calls[0];
  assert.equal(c.url, `${API}/repos/o/r/actions/workflows/agent-dev.yml/dispatches`);
  assert.equal(c.init.method, "POST");
  assert.equal(c.init.headers.Authorization, "Bearer t0ken");
  assert.ok(c.init.headers["User-Agent"]);
  assert.deepEqual(c.body, { ref: "main", inputs: { mode: "scheduled" } });
});

test("startRow: anything but 204 is a problem that names the workflow and status", async () => {
  for (const status of [200, 401, 404, 422, 500]) {
    const f = fakeFetch([["/dispatches", { status, body: '{"message":"nope"}' }]]);
    const r = await startRow(dev, { fetch: f, token: "t", api: API });
    assert.equal(r.ok, false, `status ${status}`);
    assert.match(r.problem, new RegExp(`Could not start o/r agent-dev\\.yml: GitHub answered ${status}`));
  }
});

test("startRow: a network error is a problem, not a throw", async () => {
  const f = fakeFetch([["/dispatches", new Error("connection reset")]]);
  const r = await startRow(dev, { fetch: f, token: "t", api: API });
  assert.equal(r.ok, false);
  assert.match(r.problem, /connection reset/);
});

test("checkRow: asks for manually started runs created since the start time", async () => {
  const f = fakeFetch([["/runs", { status: 200, body: '{"total_count":1,"workflow_runs":[{}]}' }]]);
  const r = await checkRow(dev, new Date(utc(7, 17)), { fetch: f, token: "t0ken", api: API });
  assert.equal(r.ok, true);
  const u = new URL(f.calls[0].url);
  assert.equal(u.pathname, "/repos/o/r/actions/workflows/agent-dev.yml/runs");
  assert.equal(u.searchParams.get("event"), "workflow_dispatch");
  assert.equal(u.searchParams.get("created"), ">=2026-11-26T07:17:00Z");
  assert.equal(f.calls[0].init.headers.Authorization, "Bearer t0ken");
});

test("checkRow: no run since then is a problem", async () => {
  const f = fakeFetch([["/runs", { status: 200, body: '{"total_count":0,"workflow_runs":[]}' }]]);
  const r = await checkRow(dev, new Date(utc(7, 17)), { fetch: f, token: "t", api: API });
  assert.equal(r.ok, false);
  assert.match(r.problem, /o\/r agent-dev\.yml should have started at 2026-11-26T07:17:00Z, but no run has been created since/);
});

test("checkRow: a failed or unreadable answer is a problem, never a pass", async () => {
  const answers = [{ status: 403, body: '{"message":"forbidden"}' }, { status: 200, body: "not json" }, { status: 200, body: "{}" }, new Error("timeout")];
  for (const answer of answers) {
    const f = fakeFetch([["/runs", answer]]);
    const r = await checkRow(dev, new Date(utc(7, 17)), { fetch: f, token: "t", api: API });
    assert.equal(r.ok, false);
    assert.match(r.problem, /Could not check o\/r agent-dev\.yml/);
  }
});

// ---- token expiry ----

test("parseTokenExpiry: GitHub's formats, and nothing for junk", () => {
  assert.equal(parseTokenExpiry("2026-12-25 09:00:00 UTC").toISOString(), "2026-12-25T09:00:00.000Z");
  assert.equal(parseTokenExpiry("2026-12-25 09:00:00 -0500").toISOString(), "2026-12-25T14:00:00.000Z");
  assert.equal(parseTokenExpiry("2026-12-25 09:00:00 +01:00").toISOString(), "2026-12-25T08:00:00.000Z");
  assert.equal(parseTokenExpiry(null), null);
  assert.equal(parseTokenExpiry(""), null);
  assert.equal(parseTokenExpiry("soon"), null);
});

test("tokenExpiryWarning: warns under 14 days, silent at 14 or with no header", () => {
  const base = utc(6, 17);
  const now = new Date(base);
  const day = 24 * 60 * 60 * 1000;
  const at = (ms) => new Date(base + ms).toISOString().replace("T", " ").replace(/\.\d{3}Z$/, " UTC");
  assert.equal(tokenExpiryWarning(null, now, 14), null);
  assert.equal(tokenExpiryWarning(at(14 * day), now, 14), null);
  assert.equal(tokenExpiryWarning(at(300 * day), now, 14), null);
  assert.match(tokenExpiryWarning(at(14 * day - 1000), now, 14), /expires on 2026-12-10 \(13 days left\)/);
  assert.match(tokenExpiryWarning(at(1.5 * day), now, 14), /\(1 day left\)/);
  assert.match(tokenExpiryWarning(at(-day), now, 14), /expired on 2026-11-25/);
});

// ---- Discord ----

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

// ---- a whole tick ----

test("runTick: a tick with nothing due makes no request at all", async () => {
  const f = fakeFetch([]);
  const r = await tick(utc(9, 37), f);
  assert.deepEqual(r, { time: "09:37", started: [], checked: [], problems: [] });
  assert.equal(f.calls.length, 0);
});

test("runTick: the 07:17 tick starts dev and is quiet on 204", async () => {
  const f = fakeFetch([["/dispatches", { status: 204 }]]);
  const r = await tick(utc(7, 17), f);
  assert.deepEqual(r, { time: "07:17", started: ["o/r agent-dev.yml"], checked: [], problems: [] });
  assert.equal(f.calls.length, 1);
  assert.match(f.calls[0].url, /agent-dev\.yml\/dispatches$/);
});

test("runTick: a refused start goes to Discord, without the token", async () => {
  const f = fakeFetch([["/dispatches", { status: 401, body: '{"message":"Bad credentials"}' }], [HOOK, { status: 204 }]]);
  const r = await tick(utc(7, 17), f);
  assert.deepEqual(r.started, []);
  assert.equal(r.problems.length, 1);
  const hook = f.calls.find((c) => c.url === HOOK);
  assert.match(hook.body.content, /Could not start o\/r agent-dev\.yml: GitHub answered 401/);
  assert.doesNotMatch(hook.body.content, /t0ken/);
});

test("runTick: the 07:27 tick checks dev since 07:17 and alerts when no run exists", async () => {
  const f = fakeFetch([["/runs", { status: 200, body: '{"total_count":0}' }], [HOOK, { status: 204 }]]);
  const r = await tick(utc(7, 27), f);
  assert.deepEqual(r.checked, []);
  assert.equal(new URL(f.calls[0].url).searchParams.get("created"), ">=2026-11-26T07:17:00Z");
  assert.match(f.calls.find((c) => c.url === HOOK).body.content, /no run has been created since/);
});

test("runTick: the check is quiet when the run exists", async () => {
  const f = fakeFetch([["/runs", { status: 200, body: '{"total_count":1}' }]]);
  const r = await tick(utc(7, 27), f);
  assert.deepEqual(r, { time: "07:27", started: [], checked: ["o/r agent-dev.yml"], problems: [] });
  assert.equal(f.calls.length, 1);
});

test("runTick: the 00:07 tick checks last night's 23:57 start in the other repo", async () => {
  const f = fakeFetch([["/repos/o/two/actions/workflows/nightly.yml/runs", { status: 200, body: '{"total_count":1}' }]]);
  const r = await tick(utc(0, 7, 27), f);
  assert.deepEqual(r.checked, ["o/two nightly.yml"]);
  assert.equal(new URL(f.calls[0].url).searchParams.get("created"), ">=2026-11-26T23:57:00Z");
});

test("runTick: the token warning is sent on the 06:17 tick only", async () => {
  const soon = { "github-authentication-token-expiration": "2026-12-01 00:00:00 UTC" };
  const f = fakeFetch([["/dispatches", { status: 204, headers: soon }], [HOOK, { status: 204 }]]);
  const other = await tick(utc(7, 17), f);
  assert.deepEqual(other.problems, []);
  const daily = await tick(utc(6, 17), f);
  assert.deepEqual(daily.started, ["o/r agent-backlog.yml"]);
  assert.equal(daily.problems.length, 1);
  assert.match(daily.problems[0], /token expires on 2026-12-01 \(4 days left\)/);
  assert.equal(f.calls.filter((c) => c.url.includes("/rate_limit")).length, 0, "the start's own response is used");
});

test("runTick: a token with plenty of time left says nothing", async () => {
  const far = { "github-authentication-token-expiration": "2027-11-01 00:00:00 UTC" };
  const f = fakeFetch([["/dispatches", { status: 204, headers: far }]]);
  const r = await tick(utc(6, 17), f);
  assert.deepEqual(r.problems, []);
});

test("runTick: with no start on the token tick, one extra request reads the header", async () => {
  const soon = { "github-authentication-token-expiration": "2026-12-01 00:00:00 UTC" };
  const f = fakeFetch([["/rate_limit", { status: 200, body: "{}", headers: soon }], [HOOK, { status: 204 }]]);
  const r = await tick(utc(9, 37), f, { tokenCheckAt: "09:37" });
  assert.equal(r.problems.length, 1);
  assert.match(r.problems[0], /token expires on 2026-12-01/);
});

test("runTick: a missing token is reported and nothing is sent to GitHub", async () => {
  const f = fakeFetch([[HOOK, { status: 204 }]]);
  const r = await tick(utc(7, 17), f, { env: { DISCORD_WEBHOOK_URL: HOOK, GITHUB_API: API } });
  assert.match(r.problems[0], /No GITHUB_TOKEN/);
  assert.deepEqual(f.calls.map((c) => c.url), [HOOK]);
});

test("runTick: the real GitHub address is the default", async () => {
  const f = fakeFetch([["https://api.github.com/repos/o/r/actions/workflows/agent-dev.yml/dispatches", { status: 204 }]]);
  const r = await tick(utc(7, 17), f, { env: { GITHUB_TOKEN: "t", DISCORD_WEBHOOK_URL: HOOK } });
  assert.deepEqual(r.started, ["o/r agent-dev.yml"]);
});
