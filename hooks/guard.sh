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
#   - loosen the rules: write to rulesets or branch protection through gh api
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
  # never a live-check PR), so an agent neither adds, removes nor sets them. A label flag
  # naming one is allowed only in a read (gh issue/pr list|view|status) with no edit or
  # create anywhere in the command. (sprint-publish.sh sets agent:live-check itself;
  # the gate also checks the label history, see lib/merge-gate.jq.)
  if grep -qE -- '(--add-label|--remove-label|--label|(^| )-l)( |=)?[^;&|]*(risk:|agent:live-check)' <<<"$norm"; then
    if ! grep -qE '(^|[^[:alnum:]_-])gh .*(^| )(list|view|status)( |$)' <<<"$norm" \
       || grep -qE '(^| )(edit|create|api)( |$)' <<<"$norm"; then
      block "risk:* and agent:live-check labels are the owner's (and triage's): an agent never adds, removes or replaces them."
    fi
  fi
  # Labels themselves (create, rename, recolor, delete, clone) are the owner's: renaming
  # risk:medium to risk:low would change every issue at once.
  grep -qE '(^|[^[:alnum:]_-])gh( +-[^ ]+( +[^ -][^ ]*)?)* +label +(create|edit|delete|clone)( |$)' <<<"$norm" \
    && block "labels are created, renamed and deleted by the owner (bootstrap-labels.sh), never by an agent."
  # Any API write that touches labels, whatever the endpoint: a labels path, a labels
  # field on an issue or PR (PATCH issues/N -f labels[]=...), or a GraphQL label mutation
  # (removeLabelsFromLabelable, clearLabelsFromLabelable, updateIssue with labelIds, ...).
  # Labels are added with gh issue edit --add-label; nothing else changes them.
  apiw='(-x|--method)( |=)*(delete|put|patch|post)|( -f| -F| --field| --raw-field| --input)( |=)'
  if grep -qE '(^|[^[:alnum:]_-])gh +api( |$)' <<<"$norm"; then
    if grep -q 'label' <<<"$norm" && grep -qiE "$apiw|mutation" <<<"$flat"; then
      block "labels are changed only with gh issue edit --add-label, never through the API (needs:human, risk:* and agent:live-check are the owner's)."
    fi
    # What the command text cannot show: a GraphQL query from a file or stdin, any
    # GraphQL mutation, and a write to an issue or PR itself (its labels, state, body).
    # Agents use gh issue/pr commands for those.
    if grep -qE '(^| )graphql( |$)' <<<"$norm" && grep -qE 'mutation|=@|--input' <<<"$norm"; then
      block "no GraphQL mutations (or queries from a file) through gh api. Use gh issue/pr commands."
    fi
    if grep -qE 'repos/[^ /]+/[^ /]+/(issues|pulls)/[0-9]+([ ?]|$)' <<<"$norm" && grep -qiE "$apiw" <<<"$flat"; then
      block "no API writes to an issue or PR itself (labels, state, body). Use gh issue/pr commands."
    fi
  fi
  if grep -qE '(^|[^[:alnum:]_-])gh +api( |$)' <<<"$flat" && grep -qE 'rulesets|/protection([^[:alnum:]]|$)' <<<"$flat" \
     && grep -qiE '(-X|--method)[ =]*(PUT|PATCH|POST|DELETE)|( -f | -F | --field | --raw-field | --input )' <<<"$flat"; then
    block "rulesets and branch protection are the owner's. An agent never changes a gate to get past it."
  fi
fi

# --- the plugin itself ---
if [[ -n "$root" ]] && grep -qF -- "$root" <<<"$flat"; then
  grep -qE '(sed +-i|>|(^|[ ;&|])(rm|mv|cp|tee|chmod|truncate|ln|install|patch|git) )' <<<"$flat" \
    && block "the installed agent-loop plugin is not changed by an agent. Use a PR in its repository (skill process-fix)."
fi
exit 0
