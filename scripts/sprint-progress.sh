#!/usr/bin/env bash
# Report sprint progress: one line to Discord (discord.sh; printed when no webhook), and
# the same line added to one progress comment on the release issue, edited in place.
# The release issue is the open one the loop filed (lib/release.jq rules: owner, release
# label, <!-- agent-release --> marker), or the number given. No release issue: Discord
# only. The comment is found by its marker and the owner as author.
# Usage: sprint-progress.sh "LINE" [RELEASE_ISSUE]
# Env:   GITHUB_REPOSITORY (default: current repo), DISCORD_WEBHOOK_URL (optional)
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
line=${1:?usage: sprint-progress.sh LINE [RELEASE_ISSUE]}; rel=${2:-}
repo=${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}
owner=$(GITHUB_REPOSITORY=$repo bash "$here/scripts/loop-config.sh" | jq -r .owner_login)
line=$(jq -rn -L "$here/lib" --arg l "$line" 'include "meta"; $l | split("\n")[0] | defang_markers | .[:400]')
stamp=$(date -u +%Y-%m-%dT%H:%MZ)

printf '**Sprint: %s** %s\n' "${repo#*/}" "$line" | bash "$here/scripts/discord.sh" || echo "sprint-progress: Discord post failed" >&2

if [[ -z "$rel" ]]; then
  rel=$(gh issue list -R "$repo" --state open --label release --author "$owner" --limit 20 --json number,body \
          --jq '[.[] | select(.body | contains("<!-- agent-release -->"))] | sort_by(.number) | last | .number // empty')
fi
[[ -z "$rel" ]] && { echo "sprint-progress: no open release issue; Discord only"; exit 0; }
[[ "$rel" =~ ^[1-9][0-9]*$ ]] || { echo "sprint-progress: bad release issue '$rel'" >&2; exit 1; }

marker='<!-- agent-sprint-progress -->'
existing=$(gh api --paginate "repos/$repo/issues/$rel/comments?per_page=100" \
  --jq ".[] | select(.user.login == \"$owner\" and (.body | startswith(\"$marker\"))) | {id, body}" | jq -sc 'last // empty')
if [[ -n "$existing" ]]; then
  body=$(jq -r --arg l "- $stamp $line" '.body + "\n" + $l' <<<"$existing")
  gh api -X PATCH "repos/$repo/issues/comments/$(jq -r .id <<<"$existing")" -f body="$body" >/dev/null
else
  gh issue comment "$rel" -R "$repo" --body "$(printf '%s\n**Sprint progress**\n\n- %s %s' "$marker" "$stamp" "$line")" >/dev/null
fi
echo "sprint-progress: https://github.com/$repo/issues/$rel updated"
