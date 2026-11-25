#!/usr/bin/env bash
# PreToolUse guard for the agent-loop plugin (hooks/hooks.json). It runs before every
# Bash, Edit and Write call of a session with the plugin enabled, subagents included,
# and blocks (exit 2, reason on stderr) what a sprint agent must never do itself:
#   - merge, or turn on auto-merge, other than through merge-gate.sh
#       gh pr merge; gh api .../merge, mergePullRequest, enablePullRequestAutoMerge;
#       calling enable-automerge.sh directly
#   - speak for the owner: post or edit a comment that begins "Owner decision" or
#     "Live check passed/failed", in the command or in a body file it names
#   - undo a stop: remove needs:human, delete a label
#   - change what the gate trusts: add, remove or replace risk:* or agent:live-check
#   - loosen the rules: any gh api write (rulesets and branch protection included),
#     gh aliases and extensions
#   - change the installed plugin itself (its gates and scripts): Edit/Write under the
#     plugin root, or a shell command that names the plugin root and writes
# This is a second layer. The ruleset (required checks, no bypass) is what GitHub
# enforces; a determined shell trick can get past a text match. Commands the owner
# types with "!" in the prompt are not tool calls and are not checked.
# Usage (hooks.json): guard.sh PLUGIN_ROOT     stdin: the hook's JSON
set -uo pipefail
root=${1:-}
in=$(cat)
tool=$(jq -r '.tool_name // ""' <<<"$in")
block() { echo "agent-loop guard: $1" >&2; exit 2; }

if [[ "$tool" == Edit || "$tool" == Write || "$tool" == MultiEdit || "$tool" == NotebookEdit ]]; then
  f=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' <<<"$in")
  if [[ -n "$root" && -n "$f" ]]; then
    rp=$(realpath -m "$root"); fp=$(realpath -m "$f")
    [[ "$fp" == "$rp" || "$fp" == "$rp"/* ]] && block "the installed agent-loop plugin (its gates and scripts) is not edited by an agent. Change agent-loop through a PR in its own repository (skill process-fix)."
  fi
  exit 0
fi
[[ "$tool" == Bash ]] || exit 0
cmd=$(jq -r '.tool_input.command // ""' <<<"$in")
cwd=$(jq -r '.cwd // "."' <<<"$in")
flat=$(tr '\n\t' '  ' <<<"$cmd" | tr -s ' ')

# --- merging ---
grep -qE '(^|[^[:alnum:]_-])gh +pr +merge( |$)' <<<"$flat" && block "no direct merge. Run merge-gate.sh PR: it checks every rule and turns on auto-merge only if they all hold."
grep -qE '(^|[^[:alnum:]_-])gh +api( |$)' <<<"$flat" && grep -qiE '/merges?([^[:alnum:]_]|$)|mergePullRequest|enablePullRequestAutoMerge' <<<"$flat" \
  && block "no merge through the API. Run merge-gate.sh PR."
grep -qE 'enable-automerge\.sh' <<<"$flat" && block "enable-automerge.sh is called by merge-gate.sh only. Run merge-gate.sh PR."

# --- speaking for the owner ---
# The gate counts a comment as the owner's word only when it BEGINS with "Owner decision"
# or "Live check passed/failed" (lib/glob.jq, lib/merge-gate.jq). The same test here: a
# body argument or body file that starts with the phrase is blocked; a sentence that
# mentions it ("needs an Owner decision") is not.
lead='[[:space:]#*_>]*(Owner decision|Live check (passed|failed))'
if grep -qE '(^|[^[:alnum:]_-])gh +' <<<"$flat"; then
  # Where a body can begin: after a quote or "(", after --body/-b/body=, or at the start
  # of a line of the command (a heredoc).
  if grep -qiE "(^|[\"'(]|--body[ =]|-b |body=)$lead" <<<"$flat" || grep -qiE "^$lead" <<<"$cmd"; then
    block "only the owner writes comments that begin \"Owner decision\" or \"Live check passed/failed\". Ask the owner; stop with claim-issue.sh stop if the work cannot go on."
  fi
  # Bodies passed as files: --body-file F, -F F, -F body=@F, -f body=@F
  while read -r bf; do
    [[ -z "$bf" || "$bf" == - ]] && continue
    [[ "$bf" != /* ]] && bf="$cwd/$bf"
    [[ -f "$bf" ]] && grep -qiE "^$lead" "$bf" \
      && block "the body file $bf begins in the owner's voice (\"Owner decision\" / \"Live check ...\")."
  done < <(grep -oE '(--body-file[ =]+|-F +(body=@)?|-f +body=@)[^ ;&|]+' <<<"$flat" | sed -E 's/^(--body-file[ =]+|-F +(body=@)?|-f +body=@)//; s/^["'"'"']//; s/["'"'"']$//')
  # Label rules match a normalized copy: quotes and backslashes removed, lower case
  # (GitHub label names are case-insensitive: RISK:LOW is risk:low).
  norm=$(tr -d "\"'\\" <<<"$flat" | tr '[:upper:]' '[:lower:]')
  grep -qE -- '--remove-label( |=)?[^;&|]*needs:human' <<<"$norm" \
    && block "needs:human is removed by the owner, never by an agent."
  # risk:* and agent:live-check decide what the merge gate may auto-merge (risk:low only,
  # never a live-check PR), so an agent neither adds, removes nor sets them. A command
  # that names one with a label flag passes only when it is one plain read: a single
  # command (no ; & | $( ` or newline), gh, then issue|pr, then list|view|status (global
  # -R/--repo allowed in between). Anything else is blocked: edit, create, an alias or
  # extension, a wrapper. (sprint-publish.sh sets agent:live-check itself; the gate also
  # checks the label history on GitHub, see lib/merge-gate.jq.)
  if grep -qE -- '(--add-label|--remove-label|--label|(^| )-l)( |=)?[^;&|]*(risk:|agent:live-check)' <<<"$norm"; then
    plain_read=false
    if ! grep -qE '[;&|`]|\$\(' <<<"$norm" && [[ "$cmd" != *$'\n'* ]]; then
      read -ra t <<<"$norm"; k=1
      skip() { while [[ "${t[k]:-}" == -r || "${t[k]:-}" == --repo ]]; do k=$((k+2)); done
               while [[ "${t[k]:-}" == --repo=* || "${t[k]:-}" == -r?* ]]; do k=$((k+1)); done; }
      if [[ "${t[0]:-}" == gh ]]; then
        skip; sub=${t[k]:-}; k=$((k+1)); skip; verb=${t[k]:-}
        [[ "$sub" =~ ^(issue|pr)$ && "$verb" =~ ^(list|view|status)$ ]] && plain_read=true
      fi
    fi
    $plain_read || block "risk:* and agent:live-check labels are the owner's (and triage's): an agent never adds, removes or replaces them."
  fi
  # Labels themselves (create, rename, recolor, delete, clone) are the owner's: renaming
  # risk:medium to risk:low would change every issue at once. Aliases and extensions
  # could rename any gh command, so an agent does not define or install them.
  grep -qE '(^|[^[:alnum:]_-])gh( +-[^ ]+( +[^ -][^ ]*)?)* +label +(create|edit|delete|clone)( |$)' <<<"$norm" \
    && block "labels are created, renamed and deleted by the owner (bootstrap-labels.sh), never by an agent."
  grep -qE '(^|[^[:alnum:]_-])gh( +-[^ ]+( +[^ -][^ ]*)?)* +(alias +(set|import|delete)|extension +(install|upgrade|create|exec)|ext +(install|upgrade|create|exec))( |$)' <<<"$norm" \
    && block "gh aliases and extensions are the owner's: an agent does not define or install them."
  # gh api: an agent only reads. Every write is blocked, whatever the endpoint: a field
  # flag (-f/-F, attached or clustered like -fx=1 or -iF, --field, --raw-field, --input),
  # a method other than GET (-X, -XPOST, --method=patch), or GraphQL (always a POST).
  # Agents write with gh issue/pr commands, which the rules above check. A gh api call
  # whose arguments come from the shell ($VAR other than $R, $(...), backticks) cannot be
  # read here, so it is blocked too.
  if grep -qE '(^|[^[:alnum:]_-])gh( +-[^ ]+( +[^ -][^ ]*)?)* +api( |$)' <<<"$norm"; then
    apiw=false
    grep -qE -- '(^| )--(field|raw-field|input)([ =]|$)|(^| )-[a-z]*f' <<<"$norm" && apiw=true
    grep -qE '(^| )graphql( |$)' <<<"$norm" && apiw=true
    while read -r m; do [[ -n "$m" && "$m" != get ]] && apiw=true; done \
      < <(grep -oE -- '(--method( |=)*|(^| )-[a-z]*x *)[a-z]*' <<<"$norm" | sed -E 's/.*[ =x]//')
    if grep -qE '`|\$\(' <<<"$flat" || sed -E 's/\$\{?R\}?([^[:alnum:]_]|$)/\1/g' <<<"$flat" | grep -q '\$'; then
      block "gh api with shell expansions (other than \$R) cannot be checked. Write the command out literally."
    fi
    $apiw && block "gh api is read-only for an agent (no fields, no -X other than GET, no GraphQL). Use gh issue/pr commands to write."
  fi
fi

# --- the plugin itself ---
if [[ -n "$root" ]] && grep -qF -- "$root" <<<"$flat"; then
  grep -qE '(sed +-i|>|(^|[ ;&|])(rm|mv|cp|tee|chmod|truncate|ln|install|patch|git) )' <<<"$flat" \
    && block "the installed agent-loop plugin is not changed by an agent. Use a PR in its repository (skill process-fix)."
fi
exit 0
