#!/usr/bin/env bash
# One-time: create the labels the loop uses. Safe to re-run.
# Usage: bootstrap-labels.sh OWNER/REPO
set -euo pipefail
repo=$1
while IFS='|' read -r name color desc; do
  gh label create "$name" -R "$repo" --color "$color" --description "$desc" --force
done <<'EOF'
risk:low|0e8a16|Small, safe, verifiable change
risk:medium|fbca04|Needs care or judgment
risk:high|d93f0b|Security, data, release, or broad impact
type:bug|d73a4a|Something is broken
type:feature|a2eeef|New capability
type:docs|0075ca|Documentation only
type:test|bfd4f2|Tests only
type:refactor|c5def5|No behavior change
type:chore|ededed|Maintenance
agent:ready|1d76db|An unattended agent may pick this up
agent:in-progress|5319e7|An agent is working on this now
agent:urgent|b60205|Owner-applied: run the dev agent on this now
needs:human|e99695|Owner must decide or clarify
EOF
