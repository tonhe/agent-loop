# Sprint mode: merge gate, loop config, claims, reports, local selection, overlap.
# Sourced by test/run.sh (uses its check(), $root, $pass and $fail).

# ---------- merge-gate.jq: the decision ----------
sha=0123456789abcdef0123456789abcdef01234567
mg_ok=$(jq -nc --arg sha "$sha" '{
  owner: "tonhe", is_loop_repo: false,
  pr: {number: 50, state: "OPEN", isDraft: false, isCrossRepository: false, author: {login: "tonhe"},
       headRefName: "issue-36", headRefOid: $sha, baseRefName: "main", mergeable: "MERGEABLE",
       body: "Fix.\n\nCloses #36\n\n<!-- agent-loop issue=36 -->", labels: [], comments: []},
  issue: {number: 36, state: "OPEN", author: {login: "tonhe"}, body: "Do the thing.", labels: [{name: "risk:low"}], comments: []},
  files: ["internal/x.go", "internal/x_test.go"], files_complete: true, protected_hits: [],
  protected_review_paths: "internal/probe/family.go\ninternal/sysprobe/**\n",
  rules: [{type: "required_status_checks", parameters: {strict_required_status_checks_policy: false,
           required_status_checks: [{context: "test"}, {context: "review / agent-review"}, {context: "lab"}]}}],
  checks: [{id: 3, name: "lab", status: "completed", conclusion: "success"},
           {id: 2, name: "review / agent-review", status: "completed", conclusion: "success"},
           {id: 1, name: "test", status: "completed", conclusion: "success"},
           {id: 0, name: "CodeRabbit", status: "completed", conclusion: "neutral"}],
  statuses: [], behind_by: 0}')
mg() {  # jq edit applied to the passing facts -> "ok|reason; reason"
  jq -c "$1" <<<"$mg_ok" | jq -r -L "$root/lib" 'include "merge-gate"; merge_gate | "\(.ok)|\(.reasons | join("; "))"'
}
mgc() { mg "$1" | cut -d'|' -f1; }                    # just ok
mgr() { mg "$1" | cut -d'|' -f2-; }                   # just reasons
check "gate: a loop PR with every check green passes" "true|" "$(mg .)"
check "gate: a pending required check refuses" "false" "$(mgc '.checks[0].status = "in_progress" | .checks[0].conclusion = null')"
check "gate: a pending check is named" 'required check "lab" has not finished (pending or not reported)' "$(mgr '.checks[0].status = "queued"')"
check "gate: a required check that never reported refuses" 'required check "lab" has not finished (pending or not reported)' "$(mgr '.checks |= map(select(.name != "lab"))')"
check "gate: a failed required check refuses" 'required check "test" failed: failure' "$(mgr '.checks[2].conclusion = "failure"')"
check "gate: a cancelled required check refuses" 'required check "test" failed: cancelled' "$(mgr '.checks[2].conclusion = "cancelled"')"
check "gate: a skipped required check is not a pass" 'required check "lab" was skipped or neutral, not passed' "$(mgr '.checks[0].conclusion = "skipped"')"
check "gate: a neutral required check is not a pass" "false" "$(mgc '.checks[1].conclusion = "neutral"')"
check "gate: a failed check that is not required does not matter" "true" "$(mgc '.checks[3].conclusion = "failure"')"
check "gate: the newest run of a check counts (re-run passed)" "true" \
  "$(mgc '.checks = [{id: 9, name: "test", status: "completed", conclusion: "success"}] + (.checks | map(if .name == "test" then .conclusion = "failure" else . end))')"
check "gate: the newest run of a check counts (re-run failed)" "false" \
  "$(mgc '.checks = [{id: 9, name: "test", status: "completed", conclusion: "failure"}] + .checks')"
check "gate: a commit status can satisfy a required context" "true" \
  "$(mgc '.checks |= map(select(.name != "lab")) | .statuses = [{id: 1, context: "lab", state: "success"}]')"
check "gate: a pending commit status refuses" "false" \
  "$(mgc '.checks |= map(select(.name != "lab")) | .statuses = [{id: 1, context: "lab", state: "pending"}]')"
check "gate: no required checks at all refuses" "base branch main has no required status checks" "$(mgr '.rules = []')"
check "gate: required checks from several rulesets all count" 'required check "extra" has not finished (pending or not reported)' \
  "$(mgr '.rules += [{type: "required_status_checks", parameters: {required_status_checks: [{context: "extra"}]}}]')"

check "gate: a protected_paths hit refuses" '"Makefile"' "$(mgr '.protected_hits = ["Makefile"]' | grep -o '"Makefile"')"
check "gate: .github/ is process" "false|1" "$(mgc '.files += [".github/workflows/ci.yml"]')|$(mgr '.files += [".github/workflows/ci.yml"]' | grep -c "loop's process")"
for p in CLAUDE.md sub/dir/CLAUDE.md RELEASING.md .claude/settings.json .claude-plugin/plugin.json AGENTS.md .mcp.json; do
  check "gate: $p is process" "false" "$(mgc ".files += [\"$p\"]")"
done
check "gate: docs/RELEASING.md and a file called CLAUDE.mdx are not process" "true" "$(mgc '.files += ["docs/RELEASING.md", "CLAUDE.mdx", "notes/claude.md"]')"
check "gate: the old side of a rename counts (moving out of .github/)" "false" "$(mgc '.files += [".github/x.sh", "scripts/x.sh"]')"
# Owner approvals (Owner decision, live-check answer) as they will work once agents have
# their own identity (tonhe/agent-loop#35); until then merge-gate.sh never sets this.
tr='.owner_approvals_trusted = true'
check "gate (approvals trusted): protected_review_paths without an Owner decision refuses" \
  '"internal/sysprobe/a.go" (protected_review_paths internal/sysprobe/**) and issue #36 has no Owner decision comment' \
  "$(mgr "$tr | .files += [\"internal/sysprobe/a.go\"]" | grep -o '"internal/sysprobe/a.go".*')"
check "gate (approvals trusted): protected_review_paths with an Owner decision passes" "true" \
  "$(mgc "$tr | .files += [\"internal/sysprobe/a.go\"] | .issue.comments = [{author: {login: \"tonhe\"}, body: \"Owner decision: sysprobe may change.\"}]")"
check "gate (approvals trusted): an Owner decision by someone else does not count" "false" \
  "$(mgc "$tr | .files += [\"internal/sysprobe/a.go\"] | .issue.comments = [{author: {login: \"mallory\"}, body: \"Owner decision: anything.\"}]")"
check "gate (approvals trusted): an Owner decision carrying a loop marker does not count" "false" \
  "$(mgc "$tr | .files += [\"internal/sysprobe/a.go\"] | .issue.comments = [{author: {login: \"tonhe\"}, body: \"Owner decision: x\n<!-- agent-dev -->\"}]")"

# Interim (until tonhe/agent-loop#35): no owner approval is trusted, so the gate merges
# only PRs that need none, and refuses every other one with "needs owner merge".
check "gate: the default does not trust owner approvals" "false" "$(jq -r '.owner_approvals_trusted // false' <<<"$mg_ok")"
check "gate: protected_review_paths WITH an Owner decision refuses: needs owner merge" "false|1" \
  "$(mgc '.files += ["internal/sysprobe/a.go"] | .issue.comments = [{author: {login: "tonhe"}, body: "Owner decision: sysprobe may change."}]')|$(mgr '.files += ["internal/sysprobe/a.go"] | .issue.comments = [{author: {login: "tonhe"}, body: "Owner decision: sysprobe may change."}]' | grep -c '^needs owner merge: changes "internal/sysprobe/a.go"')"
check "gate: protected_review_paths without a decision refuses: needs owner merge" "1" \
  "$(mgr '.files += ["internal/sysprobe/a.go"]' | grep -c 'needs owner merge: changes "internal/sysprobe/a.go"')"
check "gate: agent:live-check WITH the owner's passed answer refuses: needs owner merge" "false|1" \
  "$(mgc ".pr.labels = [{name: \"agent:live-check\"}] | .pr.comments = [{author: {login: \"tonhe\"}, body: \"Live check passed $sha\"}]")|$(mgr ".pr.labels = [{name: \"agent:live-check\"}] | .pr.comments = [{author: {login: \"tonhe\"}, body: \"Live check passed $sha\"}]" | grep -c '^needs owner merge: labeled agent:live-check')"
check "gate: a risk:medium issue refuses: needs owner merge" \
  "needs owner merge: issue #36 is not risk:low (risk:medium); only risk:low PRs are merged by the gate until https://github.com/tonhe/agent-loop/issues/35 is done" \
  "$(mgr '.issue.labels = [{name: "risk:medium"}]')"
check "gate: an issue with no risk label refuses: needs owner merge" "1" "$(mgr '.issue.labels = []' | grep -c '^needs owner merge: issue #36 is not risk:low (no risk label)')"
check "gate: a protected_paths hit says needs owner merge" "1" "$(mgr '.protected_hits = ["Makefile"]' | grep -c '^needs owner merge: changes protected path "Makefile"')"
check "gate: risk:low, no protected file, no live check still passes" "true|" "$(mg .)"
check "gate: no protected_review_paths configured -> nothing to decide" "true" "$(mgc '.files += ["internal/sysprobe/a.go"] | .protected_review_paths = ""')"

check "gate: issue labeled needs:human refuses" "issue #36 is labeled needs:human" "$(mgr '.issue.labels += [{name: "needs:human"}]')"
check "gate: closed issue refuses" "issue #36 is not open" "$(mgr '.issue.state = "CLOSED"')"
check "gate: someone else's issue refuses" "issue #36 was opened by mallory, not tonhe" "$(mgr '.issue.author.login = "mallory"')"
check "gate: a Release issue refuses" "issue #36 is a Release or Plan issue" "$(mgr '.issue.body = "x\n<!-- agent-release -->"')"
check "gate: the issue read must be the branch's" "false" "$(mgc '.issue.number = 37')"
check "gate: an unreadable issue refuses" "issue #36 could not be read" "$(mgr '.issue = null')"

check "gate: not a loop branch refuses" "false|1" "$(mgc '.pr.headRefName = "feat/x"')|$(mgr '.pr.headRefName = "feat/x"' | grep -c 'is not issue-N')"
check "gate: marker for another issue refuses" "false" "$(mgc '.pr.body = "<!-- agent-loop issue=37 -->"')"
check "gate: no marker refuses" "false" "$(mgc '.pr.body = "Fix."')"
check "gate: fork PR refuses" "PR comes from a fork" "$(mgr '.pr.isCrossRepository = true')"
check "gate: missing fork flag refuses" "PR comes from a fork" "$(mgr 'del(.pr.isCrossRepository)')"
check "gate: someone else's PR refuses" "PR was opened by mallory, not tonhe" "$(mgr '.pr.author.login = "mallory"')"
check "gate: draft refuses" "PR is a draft" "$(mgr '.pr.isDraft = true')"
check "gate: closed PR refuses" "PR is not open (state MERGED)" "$(mgr '.pr.state = "MERGED"')"
check "gate: agent-loop itself refuses" "false" "$(mgc '.is_loop_repo = true')"
check "gate: an incomplete file list refuses" "false" "$(mgc '.files_complete = false')"
check "gate: merge conflict refuses" "PR has merge conflicts with main" "$(mgr '.pr.mergeable = "CONFLICTING"')"
check "gate: behind the base is fine when the ruleset does not require up to date" "true" "$(mgc '.behind_by = 4')"
check "gate: behind the base refuses when the ruleset requires up to date" \
  "head is 4 commit(s) behind main and the ruleset requires it to be up to date" \
  "$(mgr '.behind_by = 4 | .rules[0].parameters.strict_required_status_checks_policy = true')"
check "gate: up to date under a strict ruleset passes" "true" "$(mgc '.rules[0].parameters.strict_required_status_checks_policy = true')"
check "gate: every reason is listed at once" "3" "$(mg '.pr.isDraft = true | .issue.labels += [{name: "needs:human"}] | .checks[0].conclusion = "failure"' | cut -d'|' -f2 | tr ';' '\n' | wc -l)"

# live check: agent:live-check waits for the owner's "Live check passed <sha>"
lc='.owner_approvals_trusted = true | .pr.labels = [{name: "agent:live-check"}]'
check "gate: agent:live-check without an answer refuses" \
  'labeled agent:live-check and the owner has not posted "Live check passed" for head 0123456' "$(mgr "$lc")"
check "gate: Live check passed naming the head passes" "true" \
  "$(mgc "$lc | .pr.comments = [{author: {login: \"tonhe\"}, body: \"Live check passed on 0123456: sudo make lab-live, 42/42.\"}]")"
check "gate: the full sha works too, with Markdown in front" "true" \
  "$(mgc "$lc | .pr.comments = [{author: {login: \"tonhe\"}, body: \"**Live check passed** $sha\"}]")"
check "gate: a live check for an older head is stale" "false" \
  "$(mgc "$lc | .pr.comments = [{author: {login: \"tonhe\"}, body: \"Live check passed abcdef1\"}]")"
check "gate: a live check with no sha does not count" "false" \
  "$(mgc "$lc | .pr.comments = [{author: {login: \"tonhe\"}, body: \"Live check passed\"}]")"
check "gate: a live check by someone else does not count" "false" \
  "$(mgc "$lc | .pr.comments = [{author: {login: \"mallory\"}, body: \"Live check passed 0123456\"}]")"
check "gate: a live check carrying a loop marker does not count" "false" \
  "$(mgc "$lc | .pr.comments = [{author: {login: \"tonhe\"}, body: \"Live check passed 0123456 <!-- agent-sprint -->\"}]")"
check "gate: the newest answer counts (failed after passed)" "the owner's live check for head 0123456 failed" \
  "$(mgr "$lc | .pr.comments = [{author: {login: \"tonhe\"}, body: \"Live check passed 0123456\"}, {author: {login: \"tonhe\"}, body: \"Live check failed 0123456: timeout\"}]")"
check "gate: the newest answer counts (passed after failed)" "true" \
  "$(mgc "$lc | .pr.comments = [{author: {login: \"tonhe\"}, body: \"Live check failed 0123456\"}, {author: {login: \"tonhe\"}, body: \"Live check passed 0123456\"}]")"
check "gate: a sentence that only mentions a live check is not an answer" "false" \
  "$(mgc "$lc | .pr.comments = [{author: {login: \"tonhe\"}, body: \"I will post Live check passed 0123456 later\"}]")"

# ---------- merge-gate.sh: facts from GitHub (stub gh), config from the base branch ----------
mgs=$(mktemp -d); mkdir -p "$mgs/bin"
cat > "$mgs/bin/gh" <<'GH'
#!/usr/bin/env bash
# Answers from files in $MG; logs every call.
echo "gh $*" >> "$MG/log"
args="$*"
jqf() { if [[ "$1" == "--jq" ]]; then jq -r "$2"; else cat; fi; }
case "$args" in
  "pr view"*"--jq .baseRefName") jq -r .baseRefName "$MG/pr.json" ;;
  "pr view"*)        cat "$MG/pr.json" ;;
  "issue view"*)     cat "$MG/issue.json" ;;
  *"contents/.github/workflows/agent-dev.yml?ref="*)    echo "${args#*ref=}" | cut -d' ' -f1 >> "$MG/refs"; jq -n --rawfile y "$MG/dev.yml" '{content: ($y | @base64)}' | jq -r .content ;;
  *"contents/.github/workflows/agent-review.yml?ref="*) jq -n --rawfile y "$MG/review.yml" '{content: ($y | @base64)}' | jq -r .content ;;
  "api repos/"*"/pulls/50 --jq .changed_files") cat "$MG/changed" ;;
  *"pulls/50/files"*"--jq [.[]"*) jq -c '[.[] | .filename, (.previous_filename // empty)]' "$MG/files.json" ;;
  *"pulls/50/files"*"--jq length"*) jq 'length' "$MG/files.json" ;;
  *"pulls/50/files"*"--jq .[].filename"*) jq -r '.[].filename' "$MG/files.json" ;;  # as real gh prints it
  *"rules/branches/"*) cat "$MG/rules.json" ;;
  *"/check-runs"*)   jq -c '[.check_runs[] | {id, name, status, conclusion}]' "$MG/checks.json" ;;
  *"/statuses"*)     echo '[]' ;;
  *"/compare/"*)     echo 0 ;;
  "pr merge"*)       echo merged-auto ;;
  "api repos/o/r/rulesets/"*) echo 0 ;;
  *) echo "unexpected gh $args" >&2; exit 1 ;;
esac
GH
chmod +x "$mgs/bin/gh"
# gh pr view / issue view answer with --json fields; the stub returns whole objects.
jq '.pr' <<<"$mg_ok" > "$mgs/pr.json"
jq '.issue' <<<"$mg_ok" > "$mgs/issue.json"
jq '[.files[] | {filename: .}]' <<<"$mg_ok" > "$mgs/files.json"
echo 2 > "$mgs/changed"
jq '.rules' <<<"$mg_ok" > "$mgs/rules.json"
jq '{check_runs: .checks}' <<<"$mg_ok" > "$mgs/checks.json"
cat > "$mgs/dev.yml" <<'Y'
on: {workflow_dispatch: {}}
jobs:
  dev:
    uses: tonhe/agent-loop/.github/workflows/dev.yml@v1
    with:
      owner_login: tonhe
      verify_command: make test-all
      protected_paths: |
        Makefile
        scripts/
Y
cat > "$mgs/review.yml" <<'Y'
jobs:
  review:
    uses: tonhe/agent-loop/.github/workflows/review.yml@v1
    with:
      owner_login: tonhe
      protected_review_paths: |
        internal/sysprobe/**
Y
cp "$mgs/dev.yml" "$mgs/dev.orig"
mgrun() { : > "$mgs/log"; : > "$mgs/refs"; PATH="$mgs/bin:$PATH" MG="$mgs" GITHUB_REPOSITORY=o/r bash "$root/scripts/merge-gate.sh" "$@" 2>&1; }
out=$(mgrun 50 --check); rc=$?
check "gate.sh: a good PR is allowed under --check and auto-merge is not touched" "0|1|0" \
  "$rc|$(grep -c 'ALLOWED' <<<"$out")|$(grep -c 'pr merge' "$mgs/log")"
check "gate.sh: the settings are read from the PR's base branch" "main" "$(cat "$mgs/refs")"
out=$(mgrun 50); rc=$?
check "gate.sh: without --check it enables auto-merge, pinned to the head it checked" "0|1" \
  "$rc|$(grep -c "^gh pr merge 50 -R o/r --auto --squash --match-head-commit $sha\$" "$mgs/log")"
jq '.[0].filename = "scripts/release.sh"' "$mgs/files.json" > "$mgs/f2" && cp "$mgs/files.json" "$mgs/files.bak" && mv "$mgs/f2" "$mgs/files.json"
out=$(mgrun 50); rc=$?
check "gate.sh: a protected_paths file (git pathspec from the dev caller) refuses and never merges" "1|1|0" \
  "$rc|$(grep -c 'changes protected path "scripts/release.sh"' <<<"$out")|$(grep -c 'pr merge' "$mgs/log")"
jq '.[0] = {filename: "cmd/x.go", previous_filename: "Makefile"}' "$mgs/files.bak" > "$mgs/files.json"
check "gate.sh: a rename out of a protected path refuses" "1" "$(mgrun 50 --check | grep -c 'protected path "Makefile"')"
jq '.[0].filename = "weird\nname.go"' "$mgs/files.bak" > "$mgs/files.json"
check "gate.sh: a file name with a newline goes through the pathspec index intact" "0" "$(mgrun 50 --check >/dev/null; echo $?)"
cp "$mgs/files.bak" "$mgs/files.json"
echo 5 > "$mgs/changed"
check "gate.sh: a file name with a newline does not count as two files" "1" "$(jq '.[0].filename = "a\nb.go"' "$mgs/files.bak" > "$mgs/files.json"; echo 3 > "$mgs/changed"; mgrun 50 --check | grep -c 'file list is incomplete')"
cp "$mgs/files.bak" "$mgs/files.json"; echo 5 > "$mgs/changed"
check "gate.sh: fewer files listed than changed_files refuses" "1" "$(mgrun 50 --check | grep -c 'file list is incomplete')"
echo 2 > "$mgs/changed"
jq '.check_runs[0].status = "in_progress"' "$mgs/checks.json" > "$mgs/c2" && cp "$mgs/checks.json" "$mgs/checks.bak" && mv "$mgs/c2" "$mgs/checks.json"
out=$(mgrun 50); rc=$?
check "gate.sh: a pending check refuses, lists why, never merges" "1|1|0" "$rc|$(grep -c 'has not finished' <<<"$out")|$(grep -c 'pr merge' "$mgs/log")"
cp "$mgs/checks.bak" "$mgs/checks.json"
jq '.labels = [{name: "needs:human"}]' "$mgs/issue.json" > "$mgs/i2" && cp "$mgs/issue.json" "$mgs/issue.bak" && mv "$mgs/i2" "$mgs/issue.json"
check "gate.sh: a needs:human issue refuses" "1" "$(mgrun 50 | grep -c 'labeled needs:human')"
cp "$mgs/issue.bak" "$mgs/issue.json"
sed -i 's/^      protected_paths: |$/      protected_paths: ${{ vars.PROTECTED }}/; /^        Makefile$/d; /^        scripts\/$/d' "$mgs/dev.yml"
out=$(mgrun 50); rc=$?
check "gate.sh: a protection list it cannot evaluate refuses (never read as empty)" "1|0" "$rc|$(grep -c 'pr merge' "$mgs/log")"
rm "$mgs/dev.yml"
out=$(mgrun 50); rc=$?
check "gate.sh: a missing dev caller refuses" "1|0" "$rc|$(grep -c 'pr merge' "$mgs/log")"
cp "$mgs/dev.orig" "$mgs/dev.yml"
check "gate.sh: a bad PR number is a usage error" "2" "$(mgrun 'x;y' >/dev/null; echo $?)"
check "gate.sh: LOOP_REPO, DEV_CALLER and REVIEW_CALLER from the environment are ignored" "0|0" \
  "$(: > "$mgs/log"; PATH="$mgs/bin:$PATH" MG="$mgs" GITHUB_REPOSITORY=o/r LOOP_REPO=x/y DEV_CALLER=lax.yml REVIEW_CALLER=lax.yml bash "$root/scripts/merge-gate.sh" 50 --check >/dev/null 2>&1; echo $?)|$(grep -c 'lax.yml' "$mgs/log")"
# LOOP_REPO cannot switch off "not agent-loop itself" (fix 3 of the security review)
check "gate.sh: LOOP_REPO from the environment cannot make agent-loop gateable" "1|1" \
  "$(: > "$mgs/log"; o=$(PATH="$mgs/bin:$PATH" MG="$mgs" GITHUB_REPOSITORY=tonhe/agent-loop LOOP_REPO=x/y bash "$root/scripts/merge-gate.sh" 50 --check 2>&1); echo "$?|$(grep -c 'agent-loop itself' <<<"$o")")"

# Config comes from the PR's base ref through the API, never from the working tree.
wt=$(mktemp -d); git -C "$wt" init -q; mkdir -p "$wt/.github/workflows"
printf 'jobs:\n  dev:\n    uses: tonhe/agent-loop/.github/workflows/dev.yml@v1\n    with:\n      owner_login: tonhe\n      protected_paths: ""\n' > "$wt/.github/workflows/agent-dev.yml"
printf 'jobs:\n  review:\n    uses: tonhe/agent-loop/.github/workflows/review.yml@v1\n    with:\n      owner_login: tonhe\n' > "$wt/.github/workflows/agent-review.yml"
jq '.[0].filename = "scripts/release.sh"' "$mgs/files.bak" > "$mgs/files.json"
out=$(cd "$wt" && : > "$mgs/log" && : > "$mgs/refs" && PATH="$mgs/bin:$PATH" MG="$mgs" GITHUB_REPOSITORY=o/r bash "$root/scripts/merge-gate.sh" 50 2>&1); rc=$?
check "gate.sh: a laxer caller in the working tree is ignored (settings come from the API)" "1|1|0" \
  "$rc|$(grep -c 'changes protected path "scripts/release.sh"' <<<"$out")|$(grep -c 'pr merge' "$mgs/log")"
check "loop-config.sh: reads the callers through the contents API at the given ref" "2|release/2" \
  "$(cd "$wt" && : > "$mgs/log" && PATH="$mgs/bin:$PATH" MG="$mgs" GITHUB_REPOSITORY=o/r bash "$root/scripts/loop-config.sh" release/2 | jq -r '.protected_paths' | grep -c .)|$(grep -o 'agent-review.yml?ref=[^ ]*' "$mgs/log" | cut -d= -f2)"
cp "$mgs/files.bak" "$mgs/files.json"
jq '.baseRefName = "develop"' "$mgs/pr.json" > "$mgs/p2" && cp "$mgs/pr.json" "$mgs/pr.bak" && mv "$mgs/p2" "$mgs/pr.json"
mgrun 50 --check >/dev/null
check "gate.sh: the settings are read at the PR's base ref, whatever it is" "develop" "$(cat "$mgs/refs")"
cp "$mgs/pr.bak" "$mgs/pr.json"
rm -rf "$wt"

# enable-automerge.sh refuses a HEAD_SHA that is not a commit id (fix 1)
check "enable-automerge.sh: a malformed HEAD_SHA refuses and never merges" "1|0" \
  "$(: > "$mgs/log"; PATH="$mgs/bin:$PATH" MG="$mgs" GITHUB_REPOSITORY=o/r HEAD_SHA='abc;x' bash "$root/scripts/enable-automerge.sh" 50 >/dev/null 2>&1; echo $?)|$(grep -c 'pr merge' "$mgs/log")"

# loop-config.sh reads only the job that calls agent-loop, never another job's with: (fix 3)
{ printf 'jobs:\n  lint:\n    uses: someone/lint/.github/workflows/lint.yml@v1\n    with:\n      owner_login: tonhe\n      protected_paths: ""\n'; sed -n '/^  dev:/,$p' "$mgs/dev.orig"; } > "$mgs/dev.yml"
check "loop-config.sh: another job's with: block in the dev caller is not read" "2" \
  "$(PATH="$mgs/bin:$PATH" MG="$mgs" GITHUB_REPOSITORY=o/r bash "$root/scripts/loop-config.sh" main | jq -r .protected_paths | grep -c .)"
cp "$mgs/dev.orig" "$mgs/dev.yml"

# Interim owner-merge rule end to end: refused, "needs owner merge", nothing enabled.
jq '.labels = [{name: "risk:medium"}]' "$mgs/issue.bak" > "$mgs/issue.json"
out=$(mgrun 50); rc=$?
check "gate.sh: a risk:medium PR is refused as needs owner merge and never merged" "1|1|0" \
  "$rc|$(grep -c '^needs owner merge: the owner reviews and merges this PR by hand' <<<"$out")|$(grep -c 'pr merge' "$mgs/log")"
cp "$mgs/issue.bak" "$mgs/issue.json"
jq --arg sha "$sha" '.labels = [{name: "agent:live-check"}] | .comments = [{author: {login: "tonhe"}, body: ("Live check passed " + $sha)}]' "$mgs/pr.bak" > "$mgs/pr.json"
out=$(mgrun 50); rc=$?
check "gate.sh: a live-check PR with a passed answer is refused as needs owner merge" "1|1|0" \
  "$rc|$(grep -c 'needs owner merge: labeled agent:live-check' <<<"$out")|$(grep -c 'pr merge' "$mgs/log")"
cp "$mgs/pr.bak" "$mgs/pr.json"
rm -rf "$mgs"

# ---------- a shared gh stub for the sprint scripts ----------
# Issues live in $SP/issues/N.json, caller workflows in $SP/dev.yml and $SP/review.yml.
# Writes are logged to $SP/log. --jq is applied like the real gh does.
sp=$(mktemp -d); mkdir -p "$sp/bin" "$sp/issues"
cat > "$sp/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "gh $*" >> "$SP/log"
args=("$@"); jqx=""
for ((i=0; i<${#args[@]}; i++)); do [[ "${args[i]}" == --jq ]] && jqx=${args[i+1]}; done
out() { if [[ -n "$jqx" ]]; then jq -rc "$jqx"; else cat; fi; }
a="$*"
case "$a" in
  "repo view"*) echo o/r ;;
  "api repos/o/r --jq .default_branch") echo main ;;
  *"contents/.github/workflows/agent-dev.yml"*)    jq -n --rawfile y "$SP/dev.yml" '{content: ($y | @base64)}' | out ;;
  *"contents/.github/workflows/agent-review.yml"*) jq -n --rawfile y "$SP/review.yml" '{content: ($y | @base64)}' | out ;;
  "issue view "*) n=${args[2]}; [[ -f "$SP/issues/$n.json" ]] || { echo "no issue $n" >&2; exit 1; }; out < "$SP/issues/$n.json" ;;
  "issue edit "*|"issue comment "*|"pr edit "*|"pr comment "*|"label create "*) : ;;
  "issue list"*"--label agent:ready"*) jq -s '[.[] | select(.state == "OPEN" and ([.labels[].name] | index("agent:ready")))]' "$SP"/issues/*.json | out ;;
  "issue list"*"--label agent:paired"*) jq -s '[.[] | select(.state == "OPEN" and ([.labels[].name] | index("agent:paired")))]' "$SP"/issues/*.json | out ;;
  "issue list"*"--milestone"*) jq -s '[.[] | select(.state == "OPEN" and .milestone.title == "v0.3.0")]' "$SP"/issues/*.json | out ;;
  "issue list"*) jq -s '[.[] | select(.state == "OPEN")]' "$SP"/issues/*.json | out ;;
  "pr list"*) if [[ -f "$SP/prs.json" ]]; then out < "$SP/prs.json"; else echo '[]' | out; fi ;;
  *"/issues/"*"/comments"*) if [[ -f "$SP/comments.json" ]]; then out < "$SP/comments.json"; else echo '[]' | out; fi ;;
  "api -X PATCH"*) : ;;
  "api graphql"*) echo '{"data":{"repository":{"issues":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}' | out ;;
  *"/milestones"*) echo '[{"number": 3, "title": "v0.3.0", "due_on": null}]' | out ;;
  *) echo "unexpected gh $a" >&2; exit 1 ;;
esac
GH
chmod +x "$sp/bin/gh"
cat > "$sp/dev.yml" <<'Y'
jobs:
  dev:
    uses: tonhe/agent-loop/.github/workflows/dev.yml@v1
    with:
      owner_login: tonhe
      git_author_name: tonhe
      git_author_email: t@example.com
      verify_command: make test-all
      selection_order: type
      protected_paths: |
        Makefile
        scripts/
Y
cat > "$sp/review.yml" <<'Y'
jobs:
  review:
    uses: tonhe/agent-loop/.github/workflows/review.yml@v1
    with:
      owner_login: tonhe
      protected_review_paths: |
        internal/sysprobe/**
Y
mkissue() {  # N labels-csv [body] [milestone] [author] [createdAt-day]
  jq -n --argjson n "$1" --arg l "$2" --arg b "${3:-Do it.}" --arg m "${4:-}" --arg a "${5:-tonhe}" --arg d "${6:-0$1}" '
    {number: $n, state: "OPEN", title: "Issue \($n)", author: {login: $a}, body: $b,
     createdAt: "2026-01-\($d[-2:])T00:00:00Z",
     labels: [$l | split(",")[] | select(. != "") | {name: .}],
     milestone: (if $m == "" then null else {number: 3, title: $m} end), comments: []}' > "$sp/issues/$1.json"
}
sprun() { PATH="$sp/bin:$PATH" SP="$sp" GITHUB_REPOSITORY=o/r "$@"; }

# ---------- loop-config.sh ----------
cfg=$(sprun bash "$root/scripts/loop-config.sh" main)
check "config: owner, verify command, author, order and both protection lists come from the callers" \
  "tonhe|make test-all|t@example.com|type|Makefile,scripts/|internal/sysprobe/**" \
  "$(jq -r '[.owner_login, .verify_command, .git_author_email, .selection_order, (.protected_paths | split("\n") | map(select(. != "")) | join(",")), (.protected_review_paths | rtrimstr("\n"))] | join("|")' <<<"$cfg")"
check "config: unset settings get dev.yml's defaults" "main|3" "$(jq -r '"\(.base_branch)|\(.max_issues)"' <<<"$cfg")"
cp "$sp/review.yml" "$sp/review.bak"; printf 'jobs:\n  other:\n    uses: x/y/.github/workflows/lax.yml@v1\n    with: {owner_login: tonhe}\n' > "$sp/review.yml"
check "config: a caller whose only with: block is not agent-loop's refuses" "1" "$(sprun bash "$root/scripts/loop-config.sh" main >/dev/null 2>&1; echo $?)"
cp "$sp/review.bak" "$sp/review.yml"

# ---------- pathspec-hits.sh: git's own pathspec matching ----------
ph() { jq -c . <<<"$1" | bash "$root/scripts/pathspec-hits.sh" "${@:2}" | jq -c .; }
check "pathspec: a directory spec covers what is under it, a file spec only that file" '["Makefile","scripts/a.sh","scripts/sub/b.sh"]' \
  "$(ph '["Makefile","Makefile.inc","scripts/a.sh","scripts/sub/b.sh","src/scripts/c.sh"]' Makefile scripts/)"
check "pathspec: globs as git reads them (* crosses /)" '["a/b/c.lock","x.lock"]' "$(ph '["x.lock","a/b/c.lock","x.lck"]' '*.lock')"
check "pathspec: no specs -> nothing" "[]" "$(ph '["Makefile"]')"
check "pathspec: names with spaces and newlines" '["scripts/a b.sh","scripts/x\ny.sh"]' "$(ph '["scripts/a b.sh","scripts/x\ny.sh","other"]' scripts/)"

# ---------- claim-issue.sh ----------
mkissue 36 agent:ready,risk:low
: > "$sp/log"
check "claim: a ready issue is claimed: in-progress on, ready off" "0|1|1" \
  "$(sprun bash "$root/scripts/claim-issue.sh" claim 36 >/dev/null 2>&1; echo $?)|$(grep -c -- 'issue edit 36 -R o/r --add-label agent:in-progress' "$sp/log")|$(grep -c -- 'issue edit 36 -R o/r --remove-label agent:ready' "$sp/log")"
mkissue 37 agent:ready,agent:in-progress
: > "$sp/log"
out=$(sprun bash "$root/scripts/claim-issue.sh" claim 37 2>&1); rc=$?
check "claim: an issue already claimed is refused and nothing is changed" "1|1|0" "$rc|$(grep -c 'already claimed' <<<"$out")|$(grep -c 'issue edit' "$sp/log")"
mkissue 38 agent:ready "x" "" mallory
check "claim: someone else's issue is refused" "1" "$(sprun bash "$root/scripts/claim-issue.sh" claim 38 >/dev/null 2>&1; echo $?)"
mkissue 39 needs:human
check "claim: a needs:human issue is refused" "1" "$(sprun bash "$root/scripts/claim-issue.sh" claim 39 >/dev/null 2>&1; echo $?)"
mkissue 40 release "x <!-- agent-release -->"
check "claim: a Release issue is refused" "1" "$(sprun bash "$root/scripts/claim-issue.sh" claim 40 >/dev/null 2>&1; echo $?)"
mkissue 41 agent:paired
check "claim: an agent:paired issue may be claimed locally" "0" "$(sprun bash "$root/scripts/claim-issue.sh" claim 41 >/dev/null 2>&1; echo $?)"
check "claim: bad usage" "2|2" "$(sprun bash "$root/scripts/claim-issue.sh" grab 36 >/dev/null 2>&1; echo $?)|$(sprun bash "$root/scripts/claim-issue.sh" claim 'x' >/dev/null 2>&1; echo $?)"

# ---------- scope-check.sh + claim-issue.sh stop: protected code without a decision ----------
# A fixture issue whose work needs internal/sysprobe/ (protected_review_paths) and has no
# Owner decision: the subagent must stop, comment, hand back and release the claim.
sc=$(mktemp -d)
git -C "$sc" init -q -b main && git -C "$sc" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
git -C "$sc" remote add origin "$sc"   # origin/main resolves to the same repo
git -C "$sc" fetch -q origin
mkissue 42 agent:ready,agent:in-progress "Fix the probe fallback in internal/sysprobe/probe.go."
mkdir -p "$sc/internal/sysprobe" && echo x > "$sc/internal/sysprobe/probe.go" && echo y > "$sc/internal/other.go"
out=$( cd "$sc" && sprun bash "$root/scripts/scope-check.sh" 42 main 2>/dev/null ); rc=$?
check "scope: a protected_review_paths file with no Owner decision -> stop" '1|false|["internal/sysprobe/probe.go"]' \
  "$rc|$(jq -r .ok <<<"$out")|$(jq -c .needs_decision <<<"$out")"
: > "$sp/log"
sprun bash "$root/scripts/claim-issue.sh" stop 42 "Needs an Owner decision: internal/sysprobe/probe.go must change. <!-- agent-loop issue=9 -->" >/dev/null 2>&1; rc=$?
check "stop: comments, adds needs:human, removes ready, releases the claim" "0|1|1|1|1" \
  "$rc|$(grep -c '^gh issue comment 42 -R o/r --body <!-- agent-sprint -->' "$sp/log")|$(grep -c -- 'issue edit 42 -R o/r --add-label needs:human' "$sp/log")|$(grep -c -- 'issue edit 42 -R o/r --remove-label agent:ready' "$sp/log")|$(grep -c -- 'issue edit 42 -R o/r --remove-label agent:in-progress' "$sp/log")"
check "stop: the reason cannot plant a marker" "1" "$(grep -c '<!--' "$sp/log")"
check "stop: needs a reason" "2" "$(sprun bash "$root/scripts/claim-issue.sh" stop 42 '  ' >/dev/null 2>&1; echo $?)"
jq '.comments = [{author: {login: "tonhe"}, body: "Owner decision: probe.go may change, only the fallback order."}]' "$sp/issues/42.json" > "$sp/i" && mv "$sp/i" "$sp/issues/42.json"
out=$( cd "$sc" && sprun bash "$root/scripts/scope-check.sh" 42 main 2>/dev/null ); rc=$?
check "scope: with an Owner decision the file is in scope (the reviewer judges how far)" '0|true|["internal/sysprobe/probe.go"]' \
  "$rc|$(jq -r .ok <<<"$out")|$(jq -c .decision_scope <<<"$out")"
mkdir -p "$sc/scripts" && echo z > "$sc/scripts/release.sh" && echo c > "$sc/CLAUDE.md"
out=$( cd "$sc" && sprun bash "$root/scripts/scope-check.sh" 42 main 2>/dev/null ); rc=$?
check "scope: protected_paths and process files stop even with a decision" '1|["scripts/release.sh"]|["CLAUDE.md"]' \
  "$rc|$(jq -c .protected <<<"$out")|$(jq -c .process <<<"$out")"
rm -rf "$sc"

# ---------- check-report.sh: a subagent's report ----------
rep() { local f; f=$(mktemp); printf '%s' "$1" > "$f"; PATH="$sp/bin:$PATH" SP="$sp" GITHUB_REPOSITORY=o/r bash "$root/scripts/check-report.sh" "$f" 2>&1; echo "rc=$?"; rm -f "$f"; }
good='{"issue": 36, "status": "pr_opened", "pr": "https://github.com/o/r/pull/50", "summary": "Fixed https://github.com/o/r/issues/36.", "noted": [{"title": "Docs miss -o", "issue": "https://github.com/o/r/issues/51"}], "live_check": null}'
check "report: a complete report is accepted" "rc=0" "$(rep "$good" | tail -1)"
check "report: a noted item without a filed issue is rejected" "1|rc=1" \
  "$(rep "$(jq -c '.noted += [{title: "Flaky test", issue: null}]' <<<"$good")" | grep -c 'noted but not filed: "Flaky test"')|$(rep "$(jq -c '.noted += [{title: "x"}]' <<<"$good")" | tail -1)"
check "report: a filed issue in another repository does not count" "rc=1" "$(rep "$(jq -c '.noted[0].issue = "https://github.com/x/y/issues/5"' <<<"$good")" | tail -1)"
check "report: a bare #N is rejected" "1" "$(rep "$(jq -c '.summary = "Fixed #36."' <<<"$good")" | grep -c 'bare issue references #36')"
check "report: owner/repo#N counts as bare too" "rc=1" "$(rep "$(jq -c '.summary = "See o/r#36."' <<<"$good")" | tail -1)"
check "report: pr_opened needs this repository's PR URL" "rc=1|rc=1" \
  "$(rep "$(jq -c 'del(.pr)' <<<"$good")" | tail -1)|$(rep "$(jq -c '.pr = "https://github.com/o/r/issues/50"' <<<"$good")" | tail -1)"
check "report: stopped needs a reason" "rc=1|rc=0" \
  "$(rep '{"issue": 36, "status": "stopped", "summary": ""}' | tail -1)|$(rep '{"issue": 36, "status": "stopped", "summary": "Needs an Owner decision."}' | tail -1)"
check "report: a live check needs its commands" "rc=1|rc=0" \
  "$(rep "$(jq -c '.live_check = {why: "sudo"}' <<<"$good")" | tail -1)|$(rep "$(jq -c '.live_check = {why: "sudo", commands: "sudo make lab"}' <<<"$good")" | tail -1)"
check "report: not JSON" "rc=2" "$(rep 'done!' | tail -1)"

# ---------- sprint-select.sh: the same selection as the nightly run ----------
rm -f "$sp"/issues/*.json
mkissue 2 agent:ready,type:feature "" "" tonhe 02
mkissue 3 agent:ready,type:bug "" "" tonhe 03
mkissue 4 agent:ready "Blocked by #2." "" tonhe 04
mkissue 5 agent:ready,type:docs "" v0.3.0 tonhe 05
mkissue 6 agent:ready "" "" mallory 06
mkissue 7 agent:paired "" v0.3.0 tonhe 07
mkissue 8 agent:paired "" "" tonhe 08
mkissue 9 agent:paired,needs:human "" v0.3.0 tonhe 09
mkissue 10 agent:ready "" "" tonhe 10
mkissue 11 agent:paired "" v0.3.0 tonhe 11
echo '[{"number": 90, "headRefName": "issue-10", "isCrossRepository": false, "author": {"login": "tonhe"}, "body": ""}]' > "$sp/prs.json"
nightly=$(sprun env OWNER_LOGIN=tonhe MAX_ISSUES=3 SELECTION_ORDER=type bash "$root/scripts/select-issues.sh" scheduled 2>/dev/null)
local_sel=$(sprun bash "$root/scripts/sprint-select.sh" v0.3.0 2>/dev/null)
check "select: the sprint's ready queue starts with exactly the nightly pick" "$nightly" "$(jq -c '.ready[:3]' <<<"$local_sel")"
check "select: ready queue (milestone first, then type order; blocked, others', busy left out)" "[5,3,2]" "$(jq -c .ready <<<"$local_sel")"
check "select: paired issues in the finish-line milestone only, not needs:human" "[7,11]" "$(jq -c .paired <<<"$local_sel")"
check "select: no milestone -> no paired issues" "[]" "$(sprun bash "$root/scripts/sprint-select.sh" 2>/dev/null | jq -c .paired)"
echo '[{"number": 91, "headRefName": "issue-7", "isCrossRepository": false, "author": {"login": "tonhe"}, "body": ""}]' > "$sp/prs.json"
check "select: a paired issue with an open loop PR is busy" "[11]" "$(sprun bash "$root/scripts/sprint-select.sh" v0.3.0 2>/dev/null | jq -c .paired)"
rm -f "$sp/prs.json"

# ---------- sprint-next.sh: what to start now ----------
# Ready queue [5,3,2,10] (#10's PR is gone now), paired [7,11]. Scopes: 5 and 3 share
# internal/a/, 2 and 7 name their own files, 10 and 11 name none (each runs alone).
for i in 5 3 2 7 11; do
  case $i in 5) b="Fix internal/a/x.go";; 3) b="Change internal/a/";; 2) b="Touch cmd/b.go";; 7) b="See docs/c.md";; 11) b="Make it faster";; esac
  jq --arg b "$b" '.body = $b' "$sp/issues/$i.json" > "$sp/i" && mv "$sp/i" "$sp/issues/$i.json"
done
nx() { sprun bash "$root/scripts/sprint-next.sh" "$@" 2>/dev/null | jq -c '[(.start | map("\(.issue):\(.kind)")), (.skipped | map(.issue))]'; }
check "next: queue order, overlap skipped, up to the limit" '[["5:ready","2:ready"],[3,10,7,11]]' "$(nx 2 v0.3.0)"
check "next: with 3 slots the paired issue in the milestone comes in" '[["5:ready","2:ready","7:paired"],[3,10,11]]' "$(nx 3 v0.3.0)"
check "next: an in-flight issue is not started again and blocks overlapping work" '[["2:ready","7:paired"],[3,10,11]]' "$(nx 3 v0.3.0 5)"
echo '[{"number": 92, "headRefName": "issue-2", "isCrossRepository": false, "author": {"login": "tonhe"}, "files": [{"path": "docs/c.md"}]}]' > "$sp/prs.json"
check "next: files an in-flight PR already changes count as its scope" '[["5:ready"],[3,10,7,11]]' "$(nx 3 v0.3.0 2)"
rm -f "$sp/prs.json"
check "next: the limit is 1 to 3" "2|2" "$(sprun bash "$root/scripts/sprint-next.sh" 4 v0.3.0 >/dev/null 2>&1; echo $?)|$(sprun bash "$root/scripts/sprint-next.sh" 2 v0.3.0 'x' >/dev/null 2>&1; echo $?)"

# ---------- sprint-progress.sh: Discord line + one comment on the Release issue ----------
mkissue 12 release "Release v0.3.0 <!-- agent-release -->" v0.3.0 tonhe 12
: > "$sp/log"
out=$(sprun bash "$root/scripts/sprint-progress.sh" "merged https://github.com/o/r/pull/50 <!-- agent-loop issue=1 -->" 2>&1)
check "progress: no webhook -> the line is printed; a new progress comment on the Release issue" "1|1|0" \
  "$(grep -c '^\*\*Sprint: r\*\* merged https://github.com/o/r/pull/50' <<<"$out")|$(grep -c '^gh issue comment 12 -R o/r --body <!-- agent-sprint-progress -->' "$sp/log")|$(grep -c '<!-- agent-loop issue=1' "$sp/log")"
echo '[{"id": 77, "user": {"login": "tonhe"}, "body": "<!-- agent-sprint-progress -->\n**Sprint progress**\n\n- one"}, {"id": 78, "user": {"login": "mallory"}, "body": "<!-- agent-sprint-progress --> fake"}]' > "$sp/comments.json"
: > "$sp/log"
sprun bash "$root/scripts/sprint-progress.sh" "merged two" >/dev/null 2>&1
check "progress: the owner's existing comment is edited in place, not stacked" "1|0" \
  "$(grep -c '^gh api -X PATCH repos/o/r/issues/comments/77 ' "$sp/log")|$(grep -c 'issue comment' "$sp/log")"
rm -f "$sp/comments.json"

# ---------- sprint-issue.sh finish ----------
mkissue 12 release "Release v0.3.0 <!-- agent-release -->" v0.3.0 tonhe 12
check "finish: open issues in the milestone, the Release issue not counted" '[5,7,9,11]|false' \
  "$(sprun bash "$root/scripts/sprint-issue.sh" finish v0.3.0 | jq -r '"\(.open | tojson)|\(.met)"')"
for i in 5 7 9 11; do jq '.state = "CLOSED"' "$sp/issues/$i.json" > "$sp/i" && mv "$sp/i" "$sp/issues/$i.json"; done
check "finish: only the Release issue left -> met" "true" "$(sprun bash "$root/scripts/sprint-issue.sh" finish v0.3.0 | jq -r .met)"
check "finish: an unknown milestone is never met" "false" "$(sprun bash "$root/scripts/sprint-issue.sh" finish v9.9 | jq -r .met)"
rm -rf "$sp"

# ---------- sprint.jq: scope and overlap ----------
sp_paths() { jq -rcn -L "$root/lib" --arg t "$1" 'include "sprint"; $t | scope_paths'; }
check "scope: paths from prose, backticks and file:line; not URLs, #N or owner/repo#N" \
  '["Makefile","README.md","cmd/via/main.go","internal/probe/family.go","internal/sysprobe/"]' \
  "$(sp_paths 'See `internal/probe/family.go:121`, cmd/via/main.go, the Makefile, e.g. this. Also https://github.com/o/r/issues/5 and #7, tonhe/viaduct#3. Touches internal/sysprobe/ and README.md.')"
check "scope: plain words are not paths" "[]" "$(sp_paths 'Make the export faster, i.e. stream it. Version 1.2.3 too.')"
check "scope: the owner's comments and the assessment count, other people's do not" '["a/b.go","c/d.go"]' \
  "$(jq -cn -L "$root/lib" 'include "sprint"; {body: "Fix a/b.go", comments: [{author: {login: "tonhe"}, body: "<!-- agent-assessment -->\nAlso c/d.go"}, {author: {login: "mallory"}, body: "and e/f.go"}]} | issue_scope("tonhe")')"
ov() { jq -rn -L "$root/lib" --argjson a "$1" --argjson b "$2" 'include "sprint"; paths_overlap($a; $b)'; }
check "overlap: same file, directory above a file, either side" "true|true|true" \
  "$(ov '["a/b.go"]' '["a/b.go"]')|$(ov '["internal/probe/"]' '["internal/probe/family.go"]')|$(ov '["internal/probe/x.go"]' '["internal"]')"
check "overlap: siblings and prefixes that are not directories do not" "false|false" \
  "$(ov '["internal/probe/a.go"]' '["internal/probe/b.go"]')|$(ov '["internal/pro"]' '["internal/probe/a.go"]')"
pp() { jq -cn -L "$root/lib" --argjson in "$1" --argjson lim "$2" 'include "sprint"; $in | pick_parallel($lim) | [(.start | map(.issue)), (.skipped | map("\(.issue):\(.why)"))]'; }
check "parallel: non-overlapping issues start up to the limit" '[[1,2],["3:parallel limit"]]' \
  "$(pp '{"in_flight": [], "candidates": [{"issue": 1, "paths": ["a/x.go"]}, {"issue": 2, "paths": ["b/y.go"]}, {"issue": 3, "paths": ["c/z.go"]}]}' 2)"
check "parallel: an overlap with an in-flight issue is skipped, the next one taken" '[[3],["2:files overlap #1"]]' \
  "$(pp '{"in_flight": [{"issue": 1, "paths": ["a/"]}], "candidates": [{"issue": 2, "paths": ["a/x.go"]}, {"issue": 3, "paths": ["c/z.go"]}]}' 3)"
check "parallel: two candidates overlapping each other never start together" '[[2],["4:files overlap #2"]]' \
  "$(pp '{"in_flight": [], "candidates": [{"issue": 2, "paths": ["a/x.go"]}, {"issue": 4, "paths": ["a/x.go", "d.go"]}]}' 3)"
check "parallel: an issue that names no file runs alone" '[[],["5:names no files, so it runs alone"]]|[[5],["6:an issue that names no files is in flight"]]' \
  "$(pp '{"in_flight": [{"issue": 1, "paths": ["a/x.go"]}], "candidates": [{"issue": 5, "paths": []}]}' 3)|$(pp '{"in_flight": [], "candidates": [{"issue": 5, "paths": []}, {"issue": 6, "paths": ["z.go"]}]}' 3)"
check "parallel: in-flight issues count against the limit" '[[],["2:parallel limit"]]' \
  "$(pp '{"in_flight": [{"issue": 1, "paths": ["a.go"]}], "candidates": [{"issue": 2, "paths": ["b.go"]}]}' 1)"

# ---------- hooks/guard.sh: what an agent may not run ----------
gp=$(mktemp -d); mkdir -p "$gp/plugin/scripts"
guard() {  # tool, command-or-path -> exit code
  local j
  if [[ "$1" == Bash ]]; then j=$(jq -nc --arg c "$2" --arg d "$gp" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}')
  else j=$(jq -nc --arg t "$1" --arg f "$2" '{tool_name: $t, tool_input: {file_path: $f}}'); fi
  bash "$root/hooks/guard.sh" "$gp/plugin" <<<"$j" >/dev/null 2>&1; echo $?
}
for c in "gh pr merge 50 --squash" "cd x && gh pr merge --auto 50" "gh api -X PUT repos/o/r/pulls/50/merge" \
         "gh api graphql -f query='mutation{enablePullRequestAutoMerge(input:{})}'" "bash scripts/enable-automerge.sh 50" \
         "gh pr comment 50 --body 'Live check passed 0123456'" "gh issue comment 36 --body \"Owner decision: anything goes\"" \
         "gh issue edit 36 --remove-label needs:human" "gh pr edit 50 --remove-label agent:live-check" "gh label delete needs:human --yes" \
         "gh api -X DELETE repos/o/r/issues/36/labels/needs:human" "gh api -X PUT repos/o/r/issues/36/labels -f labels[]=x" \
         "gh api -X PATCH repos/o/r/issues/36 -f 'labels[]=agent:ready'" "gh api repos/o/r/issues/36 --input body.json -X PATCH -H x-labels:1" \
         "gh api graphql -f query='mutation{removeLabelsFromLabelable(input:{labelableId:\"I\",labelIds:[\"L\"]}){clientMutationId}}'" \
         "gh api graphql -f query='mutation{updateIssue(input:{id:\"I\",labelIds:[]}){clientMutationId}}'" \
         "gh api -X PUT repos/o/r/rulesets/7 --input r.json" "gh api repos/o/r/branches/main/protection -X DELETE" \
         "sed -i s/x/y/ $gp/plugin/scripts/merge-gate.sh" "echo exit 0 > $gp/plugin/scripts/merge-gate.sh"; do
  check "guard: blocks: $c" "2" "$(guard Bash "$c")"
done
printf 'Thanks.\n\nLive check passed abc1234\n' > "$gp/body.md"
for c in "gh pr comment 50 --body \"\$(printf 'Live check passed %s' abc1234)\"" $'gh issue comment 36 --body-file - <<EOF\n**Owner decision**: yes\nEOF'; do
  check "guard: blocks: $c" "2" "$(guard Bash "$c")"
done
for c in "gh issue comment 36 --body 'Stopped: needs an Owner decision on probe.go'" "bash /p/scripts/claim-issue.sh stop 36 'Needs an Owner decision: x'"; do
  check "guard: allows: $c" "0" "$(guard Bash "$c")"
done
printf 'Stopped. This needs an Owner decision first.\n' > "$gp/ok.md"
check "guard: allows a body file that only mentions the phrase" "0" "$(guard Bash "gh issue comment 36 --body-file ok.md")"
check "guard: blocks a body file in the owner's voice" "2|2" "$(guard Bash "gh pr comment 50 --body-file body.md")|$(guard Bash "gh api repos/o/r/issues/1/comments -F body=@$gp/body.md")"
for c in "bash /p/scripts/merge-gate.sh 50" "gh pr view 50 --json state" "gh pr checks 50" "gh api repos/o/r/rules/branches/main" \
         "gh issue comment 36 --body-file ok.md" "git merge-base HEAD origin/main" "gh pr update-branch 50" "make test-all" \
         "gh issue edit 36 --add-label needs:human" "gh api repos/o/r/rulesets/7" "gh api repos/o/r/issues/36/labels" "gh issue view 36 --json labels" "cat $gp/plugin/scripts/merge-gate.sh"; do
  check "guard: allows: $c" "0" "$(guard Bash "$c")"
done
check "guard: Edit/Write inside the plugin are blocked, elsewhere allowed" "2|2|0" \
  "$(guard Edit "$gp/plugin/scripts/merge-gate.sh")|$(guard Write "$gp/plugin/../plugin/lib/x.jq")|$(guard Edit "$gp/project/main.go")"
check "guard: other tools pass" "0" "$(jq -nc '{tool_name: "Read", tool_input: {file_path: "/x"}}' | bash "$root/hooks/guard.sh" "$gp/plugin"; echo $?)"
rm -rf "$gp"

# ---------- the plugin's shape ----------
check "plugin: manifest and marketplace name the same plugin, at the root" "agent-loop|agent-loop|./" \
  "$(jq -r .name "$root/.claude-plugin/plugin.json")|$(jq -r '.plugins[0].name' "$root/.claude-plugin/marketplace.json")|$(jq -r '.plugins[0].source' "$root/.claude-plugin/marketplace.json")"
check "plugin: five skills, each with a name and description" "merge-gate|process-fix|review-pr|sprint|work-issue" \
  "$(for f in "$root"/skills/*/SKILL.md; do n=$(sed -n 's/^name: //p' "$f"); grep -q '^description: .\{20,\}' "$f" && echo "$n"; done | sort | paste -sd'|' -)"
check "plugin: no skill merges except through merge-gate.sh" "0" \
  "$(grep -lE 'gh pr merge|enable-automerge' "$root"/skills/*/SKILL.md | xargs -r grep -hE 'gh pr merge|enable-automerge' | grep -vcE 'never|Never|blocked|No |not|only')"
check "plugin: the guard hook covers Bash and file edits" "1|1" \
  "$(jq -r '.hooks.PreToolUse[0].matcher' "$root/hooks/hooks.json" | grep -c 'Bash')|$(jq -r '.hooks.PreToolUse[0].matcher' "$root/hooks/hooks.json" | grep -c 'Edit|Write')"
