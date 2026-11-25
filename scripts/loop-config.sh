#!/usr/bin/env bash
# Print a repository's agent-loop settings as JSON, read from its caller workflows as
# they are on a branch of GitHub (not from the working tree). The sprint skills and
# merge-gate.sh use this so local runs follow the same settings as the nightly loop, and
# so a PR cannot change the settings it is checked against: the gate reads the PR's base.
#
# Usage: loop-config.sh [REF]          REF: branch to read (default: the default branch)
# Env:   GITHUB_REPOSITORY (default: the repo of the current directory, via gh)
#        DEV_CALLER     caller of dev.yml    (default agent-dev.yml)
#        REVIEW_CALLER  caller of review.yml (default agent-review.yml)
# Out:   {"repo", "ref", "owner_login", "verify_command", "bash_allow", "git_author_name",
#         "git_author_email", "protected_paths",
#         "protected_review_paths", "base_branch", "selection_order", "max_issues"}
#        Settings a caller does not set come out as "" (or the dev.yml default for
#        base_branch, selection_order and max_issues).
# Exit:  1 when a caller cannot be read or parsed, when it has no with: block, when
#        owner_login is missing, or when a setting the gate relies on (owner_login,
#        protected_paths, protected_review_paths) is a ${{ }} expression this script
#        cannot evaluate. Refusing is safer than guessing an empty protection list.
set -euo pipefail
repo=${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}
ref=${1:-$(gh api "repos/$repo" --jq .default_branch)}
dev=${DEV_CALLER:-agent-dev.yml}
review=${REVIEW_CALLER:-agent-review.yml}

yaml2json() {
  if python3 -c 'import yaml' 2>/dev/null; then
    python3 -c 'import sys, json, yaml; json.dump(yaml.safe_load(sys.stdin), sys.stdout)'
  elif yq --version 2>&1 | grep -q 'mikefarah\|version v4'; then
    yq -o=json '.'
  else
    yq -c '.'
  fi
}

# The with: block of the job that calls agent-loop's reusable workflow ($2: dev or
# review), so another job's settings in the same file are never read instead.
caller_with() {
  local file=$1 wf=$2 raw
  raw=$(gh api "repos/$repo/contents/.github/workflows/$file?ref=$ref" --jq .content) || {
    echo "loop-config: cannot read .github/workflows/$file on $ref of $repo" >&2; return 1; }
  base64 -d <<<"$raw" | yaml2json | jq -ce --arg wf "$wf" '
    [.jobs[]? | select((.uses // "") | test("\\A[^/]+/agent-loop/\\.github/workflows/" + $wf + "\\.yml@")) | .with // {}][0]
    // error("no job calls agent-loop")' || {
    echo "loop-config: .github/workflows/$file on $ref has no job that calls agent-loop's $wf.yml" >&2; return 1; }
}

d=$(caller_with "$dev" dev)
r=$(caller_with "$review" review)

jq -n --arg repo "$repo" --arg ref "$ref" --argjson d "$d" --argjson r "$r" '
  def s: if . == null then "" else tostring end;
  {repo: $repo, ref: $ref,
   owner_login: ($d.owner_login // $r.owner_login | s),
   verify_command: ($d.verify_command | s),
   bash_allow: ($d.bash_allow | s),
   git_author_name: ($d.git_author_name | s),
   git_author_email: ($d.git_author_email | s),
   protected_paths: ($d.protected_paths | s),
   protected_review_paths: ($r.protected_review_paths | s),
   base_branch: ($d.base_branch // "main" | s),
   selection_order: ($d.selection_order // "oldest" | s),
   max_issues: ($d.max_issues // 3)}
  | if .owner_login == "" then error("owner_login is not set in the callers")
    elif ([.owner_login, .protected_paths, .protected_review_paths] | any(contains("${{")))
      then error("owner_login, protected_paths or protected_review_paths is a ${{ }} expression; set it literally")
    else . end' || { echo "loop-config: refusing ($repo@$ref)" >&2; exit 1; }
