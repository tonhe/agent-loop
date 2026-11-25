// Cloudflare Worker: starts the agent-loop workflows on a schedule, because
// GitHub's own schedule starts them hours late or not at all. See README.md.
import { schedule, CHECK_AFTER_MINUTES, TOKEN_CHECK_AT, TOKEN_WARN_DAYS } from "./config.js";
import { runTick } from "./core.js";

export default {
  async scheduled(event, env, ctx) {
    const result = await runTick({
      scheduledTime: event.scheduledTime, // the tick's time, not the clock
      schedule,
      env,
      fetch: (...args) => fetch(...args),
      checkAfterMinutes: CHECK_AFTER_MINUTES,
      tokenCheckAt: TOKEN_CHECK_AT,
      tokenWarnDays: TOKEN_WARN_DAYS,
    });
    if (result.started.length || result.checked.length || result.problems.length) {
      console.log(JSON.stringify(result));
    }
  },

  // No HTTP interface. wrangler.toml also turns the workers.dev address off.
  async fetch() {
    return new Response("Not found", { status: 404 });
  },
};
