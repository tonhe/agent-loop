#!/usr/bin/env bash
# Run a review step so that it cannot fail the job on an owner PR.
#
# The review of an owner PR is advisory: a model, a timeout or a broken step must not be
# able to block the owner's merge. With MODE=owner a failing command becomes a warning
# and a line in the step summary, and this script exits 0. With any other MODE (loop,
# empty, anything unexpected) the command's exit code is passed on unchanged, so loop
# PRs fail exactly as before.
#
# Usage: advisory.sh COMMAND [ARG...]
# Env:   MODE (review-gate.sh's mode output), GITHUB_STEP_SUMMARY (optional)
# The command is run as given, argument by argument; nothing is evaluated.
set -uo pipefail
if [[ $# -eq 0 ]]; then
  echo "advisory.sh: no command given" >&2
  rc=2
else
  "$@"
  rc=$?
fi
[[ $rc -eq 0 ]] && exit 0
if [[ "${MODE:-}" == owner ]]; then
  echo "::warning::A review step failed (exit $rc). The review of an owner PR is advisory, so the check still passes; the review may be missing or incomplete."
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    echo "Agent review (advisory): a review step failed (exit $rc), so the review could not be completed. The check passes regardless." >> "$GITHUB_STEP_SUMMARY" || true
  fi
  exit 0
fi
exit "$rc"
