#!/usr/bin/env bash
# Fill {{PLACEHOLDERS}} in a prompt template from env vars and print it.
# Usage: render-prompt.sh TEMPLATE
# Env:   VERIFY_COMMAND, PROTECTED_PATHS, PLATFORMS
set -euo pipefail
# shellcheck disable=SC2016  # the backticks are Markdown, not a command
protected=$(printf '%s\n' ".github/" "${PROTECTED_PATHS:-}" | sed '/^[[:space:]]*$/d' | sed 's/.*/`&`/' | paste -sd, - | sed 's/,/, /g')
VERIFY="${VERIFY_COMMAND:?}" PROT="$protected" PLAT="${PLATFORMS:-the platforms in CI}" \
  perl -pe 's/\{\{VERIFY_COMMAND\}\}/$ENV{VERIFY}/g; s/\{\{PROTECTED_PATHS\}\}/$ENV{PROT}/g; s/\{\{PLATFORMS\}\}/$ENV{PLAT}/g' "$1"
