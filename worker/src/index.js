// Cloudflare Worker: starts the agent-loop workflows on a schedule, because
// GitHub's own schedule starts them hours late or not at all. See README.md.
import { jobs, VERIFY_WINDOW_MINUTES, TOKEN_WARN_DAYS } from "./config.js";
import { runCron } from "./core.js";

export default {
  async scheduled(event, env, ctx) {
    const result = await runCron({
      cron: event.cron,
      scheduledTime: event.scheduledTime,
      jobs,
      env,
      fetch: (...args) => fetch(...args),
      verifyWindowMinutes: VERIFY_WINDOW_MINUTES,
      tokenWarnDays: TOKEN_WARN_DAYS,
    });
    console.log(JSON.stringify({ cron: event.cron, ...result }));
  },

  // No HTTP interface. wrangler.toml also turns the workers.dev address off.
  async fetch() {
    return new Response("Not found", { status: 404 });
  },
};
