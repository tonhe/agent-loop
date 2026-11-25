#!/usr/bin/env bash
# Fire one tick of the locally running Worker (npx wrangler dev --test-scheduled).
# Usage: tick.sh HH:MM [PORT]
#   HH:MM  a time of day in UTC, e.g. 06:17. The tick is given the most recent
#          moment that time occurred, so a check looks back from a real time.
# With real secrets in .dev.vars this starts real workflow runs.
set -euo pipefail
hhmm=${1:?usage: tick.sh HH:MM [PORT]}
port=${2:-8787}
[[ "$hhmm" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "Not a time of day: $hhmm (want HH:MM, UTC)" >&2; exit 1; }
at=$(date -u -d "today $hhmm" +%s)
now=$(date -u +%s)
if (( at > now )); then at=$(( at - 86400 )); fi
echo "tick $hhmm UTC = $(date -u -d "@$at" +%Y-%m-%dT%H:%M:%SZ)"
curl -sS "http://localhost:$port/cdn-cgi/local/scheduled?format=json&time=${at}000"
echo
