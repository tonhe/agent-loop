#!/usr/bin/env bash
# Claim, release or hand back an issue for a local sprint subagent (skills/work-issue).
# The same labels the nightly dev job uses, so the nightly run and a sprint never take
# the same issue: select.jq skips agent:in-progress.
#
# Usage: claim-issue.sh claim   ISSUE          refuse unless the issue is open, the
#                                              owner's, not a Release/Plan issue, not
#                                              needs:human and not already claimed; then
#                                              add agent:in-progress, remove agent:ready
#        claim-issue.sh release ISSUE          remove agent:in-progress
#        claim-issue.sh stop    ISSUE REASON   hand back: one comment saying what is
#                                              needed, needs:human on, agent:ready off,
#                                              claim released
# Env:   GITHUB_REPOSITORY (default: current repo), OWNER_LOGIN (default: loop-config.sh)
# Exit:  0 done, 1 refused or failed, 2 usage error.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
cmd=${1:-}; n=${2:-}
[[ "$cmd" =~ ^(claim|release|stop)$ && "$n" =~ ^[1-9][0-9]{0,8}$ ]] || {
  echo "usage: claim-issue.sh claim|release|stop ISSUE [REASON]" >&2; exit 2; }
repo=${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}
export GITHUB_REPOSITORY=$repo
owner=${OWNER_LOGIN:-$(bash "$here/scripts/loop-config.sh" | jq -r .owner_login)}
url="https://github.com/$repo/issues/$n"

issue=$(gh issue view "$n" -R "$repo" --json number,state,author,body,labels)
has() { jq -e --arg l "$1" '[.labels[].name] | index($l) != null' <<<"$issue" >/dev/null; }

case "$cmd" in
  claim)
    why=$(jq -r -L "$here/lib" --arg owner "$owner" 'include "meta";
      [ (if .state != "OPEN" then "it is not open" else empty end),
        (if .author.login != $owner then "it was opened by \(.author.login), not \($owner)" else empty end),
        (if is_meta_issue then "it is a Release or Plan issue" else empty end),
        (if ([.labels[].name] | index("needs:human")) != null then "it is labeled needs:human" else empty end),
        (if ([.labels[].name] | index("agent:in-progress")) != null then "it is already claimed (agent:in-progress)" else empty end)
      ] | join("; ")' <<<"$issue")
    if [[ -n "$why" ]]; then echo "claim: REFUSED $url: $why" >&2; exit 1; fi
    gh issue edit "$n" -R "$repo" --add-label agent:in-progress >/dev/null
    if has agent:ready; then gh issue edit "$n" -R "$repo" --remove-label agent:ready >/dev/null; fi
    echo "claimed $url"
    ;;
  release)
    if has agent:in-progress; then gh issue edit "$n" -R "$repo" --remove-label agent:in-progress >/dev/null; fi
    echo "released $url"
    ;;
  stop)
    reason=${3:-}
    [[ -n "${reason//[[:space:]]/}" ]] || { echo "claim-issue.sh stop needs a REASON" >&2; exit 2; }
    # The marker keeps this comment from counting as an Owner decision or a live-check
    # answer (lib/glob.jq, lib/merge-gate.jq); the reason is defanged like model text.
    body=$(jq -rn -L "$here/lib" --arg r "$reason" 'include "base"; include "meta"; $r | defang_base | defang_markers')
    # shellcheck disable=SC2016  # the backticks are Markdown
    gh issue comment "$n" -R "$repo" --body "$(printf '<!-- agent-sprint -->\n**Sprint agent stopped:** %s\n\nThe claim is released and the issue is labeled needs:human. Answer here (an `Owner decision` comment if a protected path must change) and remove needs:human to hand it back.' "$body")" >/dev/null
    gh issue edit "$n" -R "$repo" --add-label needs:human >/dev/null
    if has agent:ready; then gh issue edit "$n" -R "$repo" --remove-label agent:ready >/dev/null; fi
    if has agent:in-progress; then gh issue edit "$n" -R "$repo" --remove-label agent:in-progress >/dev/null; fi
    echo "stopped $url"
    ;;
esac
