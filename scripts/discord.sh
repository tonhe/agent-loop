#!/usr/bin/env bash
# Post a Markdown message to a Discord webhook. No-op when the webhook is unset.
# Usage: discord.sh < message.md     Env: DISCORD_WEBHOOK_URL
set -euo pipefail

if [[ -z "${DISCORD_WEBHOOK_URL:-}" ]]; then
  echo "DISCORD_WEBHOOK_URL not set; printing digest instead"
  cat
  exit 0
fi

msg=$(cat)
# Discord caps a message at 2000 characters.
if (( ${#msg} > 1900 )); then
  msg="${msg:0:1880}"$'\n…(truncated, see the run log)'
fi

# allowed_mentions.parse=[] means text from issue titles can never ping anyone.
jq -n --arg c "$msg" '{content: $c, allowed_mentions: {parse: []}}' \
  | curl -fsS -X POST -H 'Content-Type: application/json' --data-binary @- "$DISCORD_WEBHOOK_URL" >/dev/null
