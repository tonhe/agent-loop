#!/usr/bin/env bash
# Decide which branch the dev agent works against for one issue.
# A body line "Base: <branch>" or a label "base:<branch>" (body wins) replaces the
# default; lib/base.jq parses and validates it. The branch must already exist.
# Usage: resolve-base.sh ISSUE
# Env:   GH_TOKEN, GITHUB_REPOSITORY, OWNER_LOGIN, DEFAULT_BASE
# Prints one JSON object and exits 0, whether or not the base is usable:
#   {"ok": true,  "base": "<branch>", "source": "input"|"body"|"label", "is_default": bool, "reason": ""}
#   {"ok": false, "base": "", "source": "", "is_default": false, "reason": "<why, for the hand-back comment>"}
# is_default: the base is the repository's default branch, so "Closes #N" will close
# the issue on merge. Assumed true for the workflow's own default (source "input").
# Exits non-zero only when GitHub cannot be asked at all.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
n=$1
[[ "$n" =~ ^[0-9]+$ ]] || { echo "::error::Need an issue number, got '$n'" >&2; exit 1; }

out() {  # ok base source is_default reason
  jq -nc --argjson ok "$1" --arg base "$2" --arg source "$3" --argjson d "$4" --arg reason "$5" \
    '{ok: $ok, base: $base, source: $source, is_default: $d, reason: $reason}'
}

issue=$(gh issue view "$n" -R "$GITHUB_REPOSITORY" --json author,body,labels)
if [[ $(jq -r '.author.login' <<<"$issue") != "$OWNER_LOGIN" ]]; then
  out false "" "" false "issue #$n was not opened by $OWNER_LOGIN."; exit 0
fi

r=$(jq -c -L "$here/lib" 'include "base"; resolve_base' <<<"$issue")
err=$(jq -r '.error // ""' <<<"$r")
if [[ -n "$err" ]]; then out false "" "" false "$err"; exit 0; fi

base=$(jq -r '.base // ""' <<<"$r")
source=$(jq -r '.source // ""' <<<"$r")
if [[ -z "$base" ]]; then out true "$DEFAULT_BASE" input true ""; exit 0; fi

# Exact lookup (git/ref, not matching-refs), and compare the answer anyway.
errf=$(mktemp); rc=0
ref=$(gh api "repos/$GITHUB_REPOSITORY/git/ref/heads/$base" --jq .ref 2>"$errf") || rc=$?
apierr=$(<"$errf"); rm -f "$errf"
if [[ $rc -ne 0 ]]; then
  if grep -q 'HTTP 404' <<<"$apierr"; then ref=""
  else echo "::error::Could not check whether branch $base exists: $apierr" >&2; exit 1; fi
fi
if [[ "$ref" != "refs/heads/$base" ]]; then
  out false "" "" false "base branch \`$base\` (from the issue's $source) does not exist in this repository. Create it, or fix the issue."
  exit 0
fi

default=$(gh api "repos/$GITHUB_REPOSITORY" --jq .default_branch)
if [[ "$base" == "$default" ]]; then out true "$base" "$source" true ""
else out true "$base" "$source" false ""; fi
