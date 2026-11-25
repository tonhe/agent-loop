#!/usr/bin/env bash
# Which of these paths match these git pathspecs? Answered by git itself, so the result
# is the same as check-diff.sh's on a real diff: the names go into an empty index and
# git ls-files filters them. A name git refuses to index is an error (exit 1), never a miss.
# Usage: pathspec-hits.sh SPEC...  < ["path", ...]       Prints a JSON array of the hits.
# No specs: prints [].
set -euo pipefail
(( $# == 0 )) && { cat >/dev/null; echo '[]'; exit 0; }
idx=$(mktemp -d); trap 'rm -rf "$idx"' EXIT
git init -q "$idx"
blob=$(git -C "$idx" hash-object -w --stdin </dev/null)
jq -j --arg b "$blob" '.[] | "100644 \($b)\t\(.)\u0000"' | git -C "$idx" update-index --add -z --index-info
git -C "$idx" ls-files -z -- "$@" | jq -Rs 'split("\u0000") | map(select(. != ""))'
