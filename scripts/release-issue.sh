#!/usr/bin/env bash
# Open or refresh the owner's "Release vX.Y.Z" issue when a release is due.
# It only ever creates or edits that one issue. It never creates a tag, never creates a
# GitHub release and never approves a deployment.
#
# Data comes from the GitHub API (the backlog job's checkout is shallow and has no tags):
# the tag list, compare <latest vX.Y.Z tag>...<default branch>, open milestones, open issues.
# The decision is made by lib/release.jq (release_decision); this script fetches and applies.
# Commit messages only ever travel through files and jq: nothing here evaluates them.
#
# Usage: release-issue.sh [WORK_DIR]
# Env:   GH_TOKEN (the PAT, so the issue is the owner's), GITHUB_REPOSITORY, OWNER_LOGIN,
#        DRY_RUN (true|false), DISCORD_WEBHOOK_URL (optional),
#        RELEASE_FIX_AGE_DAYS (default 7), NOW_EPOCH (tests; default: the clock)
# Prints one line saying what it did or why it did nothing.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
repo=$GITHUB_REPOSITORY
owner=${OWNER_LOGIN:?}
dry=${DRY_RUN:-false}
days=${RELEASE_FIX_AGE_DAYS:-7}
now=${NOW_EPOCH:-$(date +%s)}
[[ "$days" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]] || { echo "::error::RELEASE_FIX_AGE_DAYS and NOW_EPOCH must be numbers" >&2; exit 1; }
w=${1:-$(mktemp -d)}; mkdir -p "$w"
name=${repo#*/}

gh api "repos/$repo/tags?per_page=100" --paginate --jq '.[].name' > "$w/release-tags.txt"
tag=$(jq -Rrn -L "$here/lib" 'include "release"; [inputs] | latest_tag // ""' < "$w/release-tags.txt")
if [[ -z "$tag" ]]; then
  echo "Release check: no vX.Y.Z tag in this repository yet; nothing to do."
  exit 0
fi

default=$(gh api "repos/$repo" --jq .default_branch)
if ! jq -en -L "$here/lib" --arg b "$default" 'include "base"; $b | valid_ref' >/dev/null; then
  echo "::error::The default branch is not a plain branch name; cannot compare against it." >&2
  exit 1
fi

# $tag passed parse_version (v<digits>.<digits>.<digits>) and $default passed valid_ref.
gh api "repos/$repo/compare/$tag...$default?per_page=100" --paginate \
  | jq -s '[.[].commits[]? | {sha, message: .commit.message, date: .commit.committer.date}]' > "$w/release-commits.json"
if [[ $(jq length "$w/release-commits.json") == 0 ]]; then
  echo "Release check: no commits on $default since $tag; nothing to do."
  exit 0
fi

gh api "repos/$repo/milestones?state=open&per_page=100" \
  --jq '[.[] | {number, title, open_issues, closed_issues}]' > "$w/release-milestones.json"
gh issue list -R "$repo" --state open --limit 500 \
  --json number,title,body,author,labels,milestone > "$w/release-issues.json"

jq -n --arg tag "$tag" --slurpfile c "$w/release-commits.json" --slurpfile m "$w/release-milestones.json" \
      --slurpfile i "$w/release-issues.json" '{tag: $tag, commits: $c[0], milestones: $m[0], issues: $i[0]}' \
  | jq -L "$here/lib" --arg owner "$owner" --argjson now "$now" --argjson days "$days" \
      'include "release"; release_decision($owner; $now; $days)' > "$w/release.json"

action=$(jq -r '.action' "$w/release.json")
note=$(jq -r '.note' "$w/release.json")
if [[ "$action" == none ]]; then
  echo "Release check: $note."
  exit 0
fi

# Built by jq from numbers only; checked again because it goes on a command line.
title=$(jq -r '.title' "$w/release.json")
[[ "$title" =~ ^Release\ v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "::error::unexpected release title" >&2; exit 1; }
n=$(jq -r '.issue // ""' "$w/release.json")
[[ "$action" == create || "$n" =~ ^[0-9]+$ ]] || { echo "::error::no issue number for $action" >&2; exit 1; }
jq -r '.body' "$w/release.json" > "$w/release-body.md"

if [[ "$dry" == true ]]; then
  case "$action" in
    create)  echo "Release check: DRY RUN, would open \"$title\" (label release, assigned to $owner)." ;;
    retitle) echo "Release check: DRY RUN, would retitle #$n to \"$title\" and refresh its body." ;;
    update)  echo "Release check: DRY RUN, would refresh the body of #$n \"$title\"." ;;
  esac
  exit 0
fi

case "$action" in
  create)
    # The label may be missing on a repo set up before release issues existed. No --force:
    # an existing label is left exactly as it is.
    gh label create release -R "$repo" --color 0052cc \
      --description "Release proposal filed by the backlog run; the owner tags" >/dev/null 2>&1 || true
    url=$(gh issue create -R "$repo" --title "$title" --body-file "$w/release-body.md" --label release --assignee "$owner")
    line="opened #${url##*/} $title ($(jq -r '.reasons | join("; ")' "$w/release.json")). Tag it yourself when ready."
    ;;
  retitle)
    gh issue edit "$n" -R "$repo" --title "$title" --body-file "$w/release-body.md" >/dev/null
    line="#$n is now $title (the version changed with the commits since $tag)."
    ;;
  update)
    gh issue edit "$n" -R "$repo" --body-file "$w/release-body.md" >/dev/null
    line="#$n $title refreshed with the latest commits."
    ;;
  *) echo "::error::unknown action $action" >&2; exit 1 ;;
esac

echo "Release check: $line"
printf '**Release: %s** %s\n' "$name" "$line" | bash "$here/scripts/discord.sh" >/dev/null \
  || echo "::warning::Could not post the release notice to Discord." >&2
