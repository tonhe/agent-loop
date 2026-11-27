# Release mode and maintenance mode, type:enhancement and the enhance: prefix (#61).
# Sourced by test/run.sh, which defines root, check, pass and fail.
# shellcheck shell=bash
# jq programs and literal $ in single quotes are what these tests pass around:
# shellcheck disable=SC2016
# shellcheck disable=SC2154  # root comes from test/run.sh

# ---------- lib/release-mode.jq: the marker ----------
ra() { jq -n -c -L "$root/lib" --arg d "$1" 'include "release-mode"; {description: $d} | release_approved'; }
check "mode: the marker line approves a milestone" "true" "$(ra 'agent-loop: release')"
check "mode: case and spaces around it do not matter" "true|true|true" \
  "$(ra '  Agent-Loop:   RELEASE  ')|$(ra $'Plan for 0.4.\n\nagent-loop: release\n')|$(ra $'notes\r\nagent-loop: release\r\n')"
check "mode: the marker inside other text, or with more on its line, does not count" "false|false|false|false" \
  "$(ra 'Not yet: agent-loop: release')|$(ra 'agent-loop: release later')|$(ra 'agent-loop:released')|$(ra 'agent-loop release')"
check "mode: no description, or not a string, is not approved" "false|false" \
  "$(jq -n -c -L "$root/lib" 'include "release-mode"; {description: null} | release_approved')|$(jq -n -c -L "$root/lib" 'include "release-mode"; {description: 7} | release_approved')"
check "mode: no open milestone -> maintenance" '{"mode":"maintenance","approved":[]}' \
  "$(jq -n -c -L "$root/lib" 'include "release-mode"; [] | release_mode')"
check "mode: an open milestone without the marker -> still maintenance (viaduct v0.4.0 before it was planned)" '{"mode":"maintenance","approved":[]}' \
  "$(jq -n -c -L "$root/lib" 'include "release-mode"; [{number: 4, title: "v0.4.0", description: "features go here"}] | release_mode')"
check "mode: an approved milestone -> release, and it is named" '{"mode":"release","approved":[{"number":4,"title":"v0.4.0"}]}' \
  "$(jq -n -c -L "$root/lib" 'include "release-mode"; [{number: 3, title: "v0.3.1", description: null}, {number: 4, title: "v0.4.0", description: "agent-loop: release"}] | release_mode')"

rok() { jq -n -c -L "$root/lib" --argjson i "$1" --argjson a "$2" 'include "release-mode"; $i | ready_allowed($a)'; }
check "mode: a feature outside an approved milestone may not be ready" "false|false" \
  "$(rok '{"labels":[{"name":"type:feature"}],"milestone":null}' '[4]')|$(rok '{"labels":[{"name":"type:feature"}],"milestone":{"number":3}}' '[4]')"
check "mode: a feature in an approved milestone may" "true" "$(rok '{"labels":[{"name":"type:feature"}],"milestone":{"number":4}}' '[4]')"
check "mode: bugs, enhancements, upkeep and unlabelled issues may in maintenance mode, in any milestone or none" "true|true|true|true|true" \
  "$(rok '{"labels":[{"name":"type:bug"}],"milestone":null}' '[]')|$(rok '{"labels":[{"name":"type:enhancement"}]}' '[]')|$(rok '{"labels":["type:docs"]}' '[]')|$(rok '{"labels":[{"name":"tech-debt"}],"milestone":{"number":3}}' '[]')|$(rok '{"labels":[]}' '[]')"

# ---------- release-mode.sh ----------
rm_=$(mktemp -d); mkdir -p "$rm_/bin"
cat > "$rm_/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "$GHLOG"
[[ -n "${S_MS:-}" ]] || { echo "gh: HTTP 502" >&2; exit 1; }
args=("$@"); jqx=""
for ((i=0; i<${#args[@]}; i++)); do [[ "${args[i]}" == --jq ]] && jqx=${args[i+1]}; done
printf '%s' "$S_MS" | jq -c "$jqx"
GH
chmod +x "$rm_/bin/gh"
rmrun() { PATH="$rm_/bin:$PATH" GHLOG="$rm_/log" GITHUB_REPOSITORY=o/r "$@"; }
out=$(rmrun env S_MS='[{"number":4,"title":"v0.4.0","description":"agent-loop: release","due_on":null,"open_issues":3}]' bash "$root/scripts/release-mode.sh")
check "release-mode.sh: an approved open milestone -> release" '{"mode":"release","approved":[{"number":4,"title":"v0.4.0"}]}' "$out"
check "release-mode.sh: it reads the open milestones" "1" "$(grep -c '^api repos/o/r/milestones?state=open&per_page=100 ' "$rm_/log")"
out=$(rmrun bash "$root/scripts/release-mode.sh" 2>"$rm_/err"); rc=$?
check "release-mode.sh: milestones unreadable -> maintenance (the safe side), a warning, exit 0" '0|{"mode":"maintenance","approved":[]}|1' \
  "$rc|$out|$(grep -c '^::warning::Could not list milestones; treating the repository as in maintenance mode' "$rm_/err")"
rm -rf "$rm_"

# ---------- validate-plan.jq: the feature gate ----------
vpf() {  # current plan [feature_ok] [decided] [allow_medium]
  jq -c --argjson allowed '[1,2,3,4,5,6]' --argjson current "$1" --argjson allow_medium "${5:-false}" \
     --argjson feature_ok "${3:-[]}" --argjson decided "${4:-[]}" -f "$root/lib/validate-plan.jq" <<<"$2"
}
curf='{"1":[],"2":["type:feature","agent:ready","risk:low"],"3":["type:feature"],"4":[],"5":["type:feature","agent:ready"],"6":[]}'
r=$(vpf "$curf" '{"actions":[{"issue":1,"add_labels":["risk:low","type:feature","agent:ready"],"remove_labels":[],"assessment":"a"}]}')
check "plan (maintenance): agent:ready refused on a new feature; risk and type kept, no needs:human" '["risk:low","type:feature"]|[]' \
  "$(jq -c '.apply[0].add_labels | sort' <<<"$r")|$(jq -c '.apply[0].remove_labels' <<<"$r")"
check "plan (maintenance): the refusal is noted for the digest" "1" \
  "$(jq -r '.apply[0].notes[]' <<<"$r" | grep -c '^agent:ready refused: type:feature outside a milestone approved for release (maintenance for this issue)')"
r=$(vpf "$curf" '{"actions":[{"issue":2,"add_labels":[],"remove_labels":[],"assessment":"a"}]}')
check "plan (maintenance): a feature that already has agent:ready loses it" '[]|["agent:ready"]' \
  "$(jq -c '.apply[0].add_labels' <<<"$r")|$(jq -c '.apply[0].remove_labels' <<<"$r")"
r=$(vpf "$curf" '{"actions":[{"issue":3,"add_labels":["risk:low","agent:ready"],"remove_labels":[],"assessment":"a"}]}')
check "plan (maintenance): the type the issue already carries counts" '["risk:low"]' "$(jq -c '.apply[0].add_labels | sort' <<<"$r")"
r=$(vpf "$curf" '{"actions":[{"issue":4,"add_labels":["risk:high","type:feature","agent:ready"],"remove_labels":[],"assessment":"a"}]}')
check "plan (maintenance): a risky feature proposed ready is not escalated to needs:human" '["risk:high","type:feature"]' "$(jq -c '.apply[0].add_labels | sort' <<<"$r")"
r=$(vpf "$curf" '{"actions":[{"issue":1,"add_labels":["risk:low","type:feature","agent:ready"],"remove_labels":[],"assessment":"a"}]}' '[1]')
check "plan (release): a feature in an approved milestone may be ready" '["agent:ready","risk:low","type:feature"]|[]' \
  "$(jq -c '.apply[0].add_labels | sort' <<<"$r")|$(jq -c '.apply[0].notes' <<<"$r")"
r=$(vpf "$curf" '{"actions":[{"issue":2,"add_labels":[],"remove_labels":[],"assessment":"a"}]}' '[2]')
check "plan (release): ... and keeps the agent:ready it has" '[]|[]' "$(jq -c '.apply[0].add_labels' <<<"$r")|$(jq -c '.apply[0].remove_labels' <<<"$r")"
r=$(vpf "$curf" '{"actions":[{"issue":1,"add_labels":["risk:low","type:bug","agent:ready"],"remove_labels":[]},{"issue":4,"add_labels":["risk:low","type:enhancement","agent:ready"],"remove_labels":[]},{"issue":6,"add_labels":["risk:low","type:docs","agent:ready"],"remove_labels":[]}]}')
check "plan (maintenance): bugs, enhancements and docs are still marked ready" '["agent:ready","risk:low","type:bug"]|["agent:ready","risk:low","type:enhancement"]|["agent:ready","risk:low","type:docs"]' \
  "$(jq -c '[.apply[].add_labels | sort] | map(tostring) | join("|")' -r <<<"$r")"
r=$(vpf "$curf" '{"actions":[{"issue":5,"add_labels":[],"remove_labels":[],"assessment":"a"}]}' '[]' '[5]')
check "plan (maintenance): an Owner decision still freezes the labels, agent:ready stays" '[]|[]' \
  "$(jq -c '.apply[0].add_labels' <<<"$r")|$(jq -c '.apply[0].remove_labels' <<<"$r")"
r=$(vpf "$curf" '{"actions":[{"issue":4,"add_labels":["risk:low","type:enhancement"],"remove_labels":[]}]}')
check "plan: type:enhancement is a managed label" '["risk:low","type:enhancement"]|[]' "$(jq -c '.apply[0].add_labels | sort' <<<"$r")|$(jq -c '.apply[0].notes' <<<"$r")"
r=$(jq -c --argjson allowed '[1]' --argjson current '{"1":[]}' --argjson allow_medium false -f "$root/lib/validate-plan.jq" \
      <<<'{"actions":[{"issue":1,"add_labels":["risk:low","type:feature","agent:ready"],"remove_labels":[]}]}')
check "plan: without feature_ok every issue counts as outside an approved milestone (the safe side)" '["risk:low","type:feature"]' "$(jq -c '.apply[0].add_labels | sort' <<<"$r")"

# ---------- candidates.jq: each candidate's milestone ----------
cm='[{"number":1,"title":"t","body":"b","labels":[],"author":{"login":"tonhe"},"createdAt":"2026-01-01T00:00:00Z","comments":[],"milestone":{"number":4,"title":"v0.4.0","description":"x"}},
     {"number":2,"title":"t","body":"b","labels":[],"author":{"login":"tonhe"},"createdAt":"2026-01-01T00:00:00Z","comments":[],"milestone":null}]'
check "candidates: each candidate carries its milestone (number and title) or null" '[{"number":4,"title":"v0.4.0"},null]' \
  "$(jq -c --arg owner tonhe --argjson max 10 --argjson open '[]' -L "$root/lib" -f "$root/lib/candidates.jq" <<<"$cm" | jq -c 'map(.milestone)')"

# ---------- apply-backlog.sh: the mode reaches the validator ----------
ab=$(mktemp -d); mkdir -p "$ab/bin" "$ab/w/claude"
printf '#!/usr/bin/env bash\necho "$*" >> "$GHLOG"\n' > "$ab/bin/gh"; chmod +x "$ab/bin/gh"
echo '[{"number":1,"title":"a","milestone":{"number":4,"title":"v0.4.0"}},{"number":2,"title":"b","milestone":{"number":3,"title":"v0.3.1"}},{"number":3,"title":"c","milestone":null}]' > "$ab/w/candidates.json"
echo '{"1":[],"2":[],"3":[]}' > "$ab/w/current-labels.json"
echo '[]' > "$ab/w/external.json"
jq -nc '{summary: "s", actions: [range(1; 4) | {issue: ., add_labels: ["risk:low", "type:feature", "agent:ready"], remove_labels: [], assessment: "ok"}]}' > "$ab/w/claude/result.json"
abr() { PATH="$ab/bin:$PATH" GHLOG="$ab/log" GITHUB_REPOSITORY=o/r OWNER_LOGIN=tonhe DRY_RUN=true bash "$root/scripts/apply-backlog.sh" "$ab/w" 2>/dev/null; }
echo '{"mode":"release","approved":[{"number":4,"title":"v0.4.0"}]}' > "$ab/w/release-mode.json"
out=$(abr)
check "apply (release): only the feature in the approved milestone is marked ready" \
  "- #1 +agent:ready,risk:low,type:feature|- #2 +risk:low,type:feature|- #3 +risk:low,type:feature" "$(grep '^- #' <<<"$out" | paste -sd'|' -)"
echo '{"mode":"maintenance","approved":[]}' > "$ab/w/release-mode.json"
check "apply (maintenance): no feature is marked ready" "0" "$(abr | grep -c 'agent:ready')"
rm -f "$ab/w/release-mode.json"
check "apply: without release-mode.json it is maintenance" "0" "$(abr | grep -c 'agent:ready')"
echo 'not json' > "$ab/w/release-mode.json"
out=$(abr); rc=$?
check "apply: an unreadable release-mode.json is maintenance too, and the run goes on" "0|0" "$rc|$(grep -c 'agent:ready' <<<"$out")"
rm -rf "$ab"

# ---------- select.jq: never a feature outside an approved milestone ----------
rs_in='{"prs":[],"issues":[
 {"number":60,"createdAt":"2026-01-01T00:00:00Z","author":{"login":"tonhe"},"labels":[{"name":"agent:ready"},{"name":"type:feature"}],"body":"","milestone":{"number":4}},
 {"number":61,"createdAt":"2026-01-02T00:00:00Z","author":{"login":"tonhe"},"labels":[{"name":"agent:ready"},{"name":"type:feature"}],"body":""},
 {"number":62,"createdAt":"2026-01-03T00:00:00Z","author":{"login":"tonhe"},"labels":[{"name":"agent:ready"},{"name":"type:bug"}],"body":""},
 {"number":63,"createdAt":"2026-01-04T00:00:00Z","author":{"login":"tonhe"},"labels":[{"name":"agent:ready"},{"name":"type:enhancement"}],"body":""},
 {"number":64,"createdAt":"2026-01-05T00:00:00Z","author":{"login":"tonhe"},"labels":[{"name":"agent:ready"},{"name":"type:feature"}],"body":"","milestone":{"number":3}},
 {"number":65,"createdAt":"2026-01-06T00:00:00Z","author":{"login":"tonhe"},"labels":[{"name":"agent:ready"},{"name":"type:docs"}],"body":"","milestone":{"number":3}}]}'
rs() { jq -c --arg owner tonhe --argjson max 20 --argjson open '[]' --argjson milestones "$1" --arg order "${2:-oldest}" -L "$root/lib" -f "$root/lib/select.jq" <<<"$rs_in"; }
check "select (maintenance): no feature is picked, even labelled agent:ready" "[65,62,63]" \
  "$(rs '[{"number":3,"dueOn":null,"description":""},{"number":4,"dueOn":null,"description":"features later"}]')"
check "select (release): the feature in the approved milestone is picked; features elsewhere are not" "[65,60,62,63]" \
  "$(rs '[{"number":3,"dueOn":null,"description":""},{"number":4,"dueOn":null,"description":"agent-loop: release"}]')"
check "select (maintenance): no milestones at all (or unreadable) -> no feature" "[62,63,65]" "$(rs '[]')"
check "select: without the milestones argument it is maintenance" "[62,63,65]" \
  "$(jq -c --arg owner tonhe --argjson max 20 --argjson open '[]' -L "$root/lib" -f "$root/lib/select.jq" <<<"$rs_in")"
check "order: type puts enhancements after upkeep and before features" "[65,60,62,63]" \
  "$(rs '[{"number":3,"dueOn":null,"description":""},{"number":4,"dueOn":null,"description":"agent-loop: release"}]' type | jq -c '.')"
check "select-issues.sh: the milestone query brings the description (the release marker)" "1" \
  "$(grep -c "milestones?state=open&per_page=100\" *\\\\\$" "$root/scripts/select-issues.sh")"
check "select-issues.sh: ... and keeps it" "1" "$(grep -c -- "--jq '\[\.\[\] | {number, dueOn: \.due_on, description}\]'" "$root/scripts/select-issues.sh")"

# ---------- release.jq: enhance is a patch, with its own notes section ----------
rci() { jq -c -L "$root/lib" 'include "release"; map(commit_info)' <<<"$1"; }
rb() { rci "$1" | jq -r -L "$root/lib" "include \"release\"; $2"; }
cms='[{"sha":"a1aaaaaa","message":"enhance(ui): show (waiting for reply) instead of *","date":"2026-11-01T00:00:00Z"},
      {"sha":"b2bbbbbb","message":"fix: crash on empty config","date":"2026-11-10T00:00:00Z"}]'
enh1=$(jq -c '.[:1]' <<<"$cms")
check "release: an enhance commit is a patch bump" "patch|v0.3.2" "$(rb "$cms" bump)|$(rb "$cms" 'next_version("v0.3.1")')"
check "release: enhance alone is a patch bump too; feat is still a minor" "patch|minor" \
  "$(rb "$enh1" bump)|$(rb '[{"sha":"c","message":"feat: x"}]' bump)"
check "release: an enhance(scope)! commit is breaking, so a minor" "minor" "$(rb '[{"sha":"c","message":"enhance(ui)!: drop the * marker"}]' bump)"
check "release: commit groups go feat, enhance, fix, other prefixes, then none" '["feat","enhance","fix","docs","other"]' \
  "$(rb '[{"sha":"1","message":"docs: a"},{"sha":"2","message":"plain"},{"sha":"3","message":"fix: b"},{"sha":"4","message":"enhance: c"},{"sha":"5","message":"feat: d"}]' 'grouped | map(.prefix) | tojson')"
now20=$(date -u -d 2026-11-20T00:00:00Z +%s)
rrr() { rci "$1" | jq -c -L "$root/lib" --argjson now "$now20" 'include "release"; {commits: ., milestones: []} | release_reasons($now; 7; "v0.3.2")'; }
check "release: an enhancement older than the fix age makes a patch release due by itself" \
  '["the oldest unreleased fix or enhancement landed on 2026-11-01, more than 7 days ago"]' "$(rrr "$enh1")"
check "release: the age trigger takes the oldest of fixes and enhancements" \
  '["the oldest unreleased fix or enhancement landed on 2026-11-01, more than 7 days ago"]' "$(rrr "$cms")"
check "release: a recent enhancement alone is not due" "[]" "$(rrr '[{"sha":"c","message":"enhance: x","date":"2026-11-18T00:00:00Z"}]')"
body=$(rb "$cms" 'release_body("v0.3.1"; "v0.3.2"; []; null; [])' 2>&1)
check "release: draft notes have an Enhancements section between Features and Fixes" "Features|Enhancements|Fixes" \
  "$(grep -oE '^### (Features|Enhancements|Fixes)$' <<<"$body" | sed 's/^### //' | paste -sd'|' -)"
check "release: the enhancement is listed under Enhancements" "1" \
  "$(awk '/^### Enhancements$/{f=1;next} /^#/{f=0} f' <<<"$body" | grep -c 'show (waiting for reply) instead of \*')"

# ---------- publish-pr.sh: no feat prefix on an issue that is not a feature ----------
nf() { jq -nr -L "$root/lib" --arg s "$1" --argjson l "$2" 'include "release-mode"; $s | no_feat_prefix($l)'; }
check "prefix: feat on an enhancement becomes enhance; scope and ! kept" "enhance: x|enhance(ui): x|enhance(ui)!: x" \
  "$(nf 'feat: x' '["type:enhancement"]')|$(nf 'feat(ui): x' '["type:enhancement","risk:low"]')|$(nf 'feat(ui)!: x' '["type:enhancement"]')"
check "prefix: feat on a bug, docs, test, refactor or chore issue takes that type's prefix" "fix: x|docs: x|test: x|refactor: x|chore: x" \
  "$(nf 'feat: x' '["type:bug"]')|$(nf 'feat: x' '["type:docs"]')|$(nf 'feat: x' '["type:test"]')|$(nf 'feat: x' '["type:refactor"]')|$(nf 'Feat: x' '["type:chore"]')"
check "prefix: a feature keeps feat; no type label changes nothing; other prefixes are left alone" "feat: x|feat: x|fix: x|feature flag: x" \
  "$(nf 'feat: x' '["type:feature","type:enhancement"]')|$(nf 'feat: x' '[]')|$(nf 'fix: x' '["type:enhancement"]')|$(nf 'feature flag: x' '["type:bug"]')"
pp=$(mktemp -d); mkdir -p "$pp/bin"
cat > "$pp/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "$GHLOG"
case "$1 $2" in
  "issue view") [[ -n "${S_LABELS:-}" ]] || { echo "gh: HTTP 502" >&2; exit 1; }; printf '%s\n' "$S_LABELS" ;;
  "pr create") echo "https://github.com/o/r/pull/9" ;;
esac
GH
cat > "$pp/bin/git" <<'GIT'
#!/usr/bin/env bash
printf 'git' >> "$GHLOG"; printf ' %s' "$@" >> "$GHLOG"; echo >> "$GHLOG"
GIT
chmod +x "$pp/bin/"*
jq -n '{commit_message:"feat(ui): show (waiting for reply)\n\nfeat: stays in the body", pr_title:"feat(ui): show (waiting for reply)", pr_body:"b"}' > "$pp/p.json"
ppr() { : > "$pp/log"; PATH="$pp/bin:$PATH" GHLOG="$pp/log" GITHUB_REPOSITORY=o/r GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t BASE_BRANCH=main PUSH_TOKEN=x \
          "$@" bash "$root/scripts/publish-pr.sh" 61 "$pp/p.json" >/dev/null 2>"$pp/err"; }
ppr env S_LABELS='["type:enhancement","risk:low"]'
check "publish: an enhancement's feat commit subject becomes enhance; the body is left alone" "1|1" \
  "$(grep -c '^git -c core.hooksPath=/dev/null commit -q -m enhance(ui): show (waiting for reply)$' "$pp/log")|$(grep -c '^feat: stays in the body$' "$pp/log")"
check "publish: ... and so does its PR title (the squash subject)" "1" "$(grep -c -- '^pr create .*--title enhance(ui): show (waiting for reply) --body' "$pp/log")"
check "publish: the labels come from the issue" "1" "$(grep -c '^issue view 61 -R o/r --json labels --jq \[\.labels\[\]\.name\]$' "$pp/log")"
ppr env S_LABELS='["type:feature"]'
check "publish: a feature keeps feat" "1|1" \
  "$(grep -c '^git -c core.hooksPath=/dev/null commit -q -m feat(ui): show' "$pp/log")|$(grep -c -- '^pr create .*--title feat(ui): show' "$pp/log")"
ppr env S_LABELS=
check "publish: labels unreadable -> the message is left as it is, with a warning, and the PR still opens" "1|1|1" \
  "$(grep -c '^git -c core.hooksPath=/dev/null commit -q -m feat(ui): show' "$pp/log")|$(grep -c '^pr create ' "$pp/log")|$(grep -c '^::warning::Could not read the labels of #61' "$pp/err")"
rm -rf "$pp"

# ---------- prompts, skills, labels, workflow, README ----------
bp="$root/prompts/backlog.md"
check "backlog prompt: type:enhancement is a type, with the tie-breaker and its examples" "1|1|1|1" \
  "$(grep -c '`type:bug`, `type:feature`, `type:enhancement`, `type:docs`' "$bp")|$(grep -c 'Does a user gain something they could not do before' "$bp")|$(grep -c '(waiting for reply)' "$bp")|$(grep -c 'a new export field' "$bp")"
check "backlog prompt: explains both modes and that a feature outside an approved milestone is not marked ready" "1|1|1" \
  "$(grep -c '^## Release mode and maintenance mode$' "$bp")|$(grep -c 'never mark a `type:feature` issue `agent:ready` unless it is in one of the approved milestones' "$bp")|$(grep -c 'Do not add `needs:human` for that alone' "$bp")"
bl="$root/.github/workflows/backlog.yml"
check "backlog.yml: the mode is decided by the tested script and shown to the model" "1|1|1" \
  "$(grep -c 'scripts/release-mode.sh" > "\$W/release-mode.json"' "$bl")|$(grep -c 'echo "## Release mode facts"' "$bl")|$(grep -c 'jq . "\$W/release-mode.json"' "$bl")"
check "backlog-candidates.sh: the issue list brings milestones" "1" "$(grep -c -- '--json number,title,body,labels,author,createdAt,comments,milestone' "$root/scripts/backlog-candidates.sh")"
check "bootstrap-labels: type:enhancement exists and says it ships in a patch" "1" \
  "$(grep -c '^type:enhancement|[0-9a-f]\{6\}|Change to existing behaviour or output; ships in a patch release$' "$root/scripts/bootstrap-labels.sh")"
check "dev prompt: enhance:, never feat, for an issue that is not type:feature" "1|1" \
  "$(grep -c 'labelled `type:enhancement`, start `commit_message` and `pr_title` with `enhance:`' "$root/prompts/dev.md")|$(grep -c 'Never start them with `feat` unless the issue is labelled `type:feature`' "$root/prompts/dev.md")"
check "work-issue skill: the same prefix rule" "1" "$(grep -c 'never `feat` unless the issue is labelled `type:feature`' "$root/skills/work-issue/SKILL.md")"
check "README: release mode and maintenance mode are documented, with the marker" "1|1|1" \
  "$(grep -c '^## Release mode and maintenance mode$' "$root/README.md")|$(grep -c '^agent-loop: release$' "$root/README.md")|$(grep -c 'GoReleaser' "$root/README.md")"
