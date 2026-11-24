#!/usr/bin/env bash
# Run Claude Code headless with hard limits and a structured result.
#
# Usage: run-claude.sh PROMPT_FILE SCHEMA_FILE OUT_DIR
# Env:   MODEL, MAX_TURNS, TIMEOUT_MIN, ALLOWED_TOOLS (comma list), CLAUDE_CODE_OAUTH_TOKEN
#
# Writes OUT_DIR/raw.json (full CLI result) and OUT_DIR/result.json (structured output).
# Exit codes: 0 ok, 124 wall-clock timeout, 3 max turns hit, 4 other Claude error.
set -euo pipefail

prompt_file=$1
schema_file=$2
out_dir=$3
mkdir -p "$out_dir"

: "${MODEL:?}" "${MAX_TURNS:?}" "${TIMEOUT_MIN:?}" "${ALLOWED_TOOLS:?}"
# Callers may wrap the list across lines; normalize to "A,B,Bash(go test:*)".
ALLOWED_TOOLS=$(tr '\n' ' ' <<<"$ALLOWED_TOOLS" | sed -E 's/[[:space:]]*,[[:space:]]*/,/g; s/^[[:space:]]+|[[:space:]]+$//g; s/,+$//')

# Tools Claude can see at all. Anything not listed here does not exist for it:
# no WebFetch, no WebSearch, no MCP servers, no subagents.
base_tools="Read,Grep,Glob,Edit,Write,Bash"

set +e
timeout --kill-after=30s "${TIMEOUT_MIN}m" \
  claude -p \
    --model "$MODEL" \
    --max-turns "$MAX_TURNS" \
    --permission-mode dontAsk \
    --tools "$base_tools" \
    --allowedTools "$ALLOWED_TOOLS" \
    --strict-mcp-config \
    --json-schema "$(cat "$schema_file")" \
    --output-format json \
    < "$prompt_file" > "$out_dir/raw.json"
rc=$?
set -e

if [[ $rc -eq 124 || $rc -eq 137 ]]; then
  echo '{"status":"too_big","summary":"Hit the wall-clock timeout."}' > "$out_dir/result.json"
  echo "::warning::Claude hit the ${TIMEOUT_MIN} minute timeout"
  exit 124
fi

if ! jq -e . "$out_dir/raw.json" >/dev/null 2>&1; then
  echo "::error::Claude produced no JSON result (exit $rc)"
  exit 4
fi

jq '{num_turns, duration_ms, subtype, is_error,
     input_tokens: .usage.input_tokens, output_tokens: .usage.output_tokens,
     cache_read: .usage.cache_read_input_tokens}' "$out_dir/raw.json" > "$out_dir/usage.json"
echo "Claude usage: $(jq -c . "$out_dir/usage.json")"

subtype=$(jq -r '.subtype // ""' "$out_dir/raw.json")
if [[ $subtype == "error_max_turns" ]]; then
  echo '{"status":"too_big","summary":"Hit the max-turns limit."}' > "$out_dir/result.json"
  echo "::warning::Claude hit --max-turns ${MAX_TURNS}"
  exit 3
fi

if [[ $(jq -r '.is_error' "$out_dir/raw.json") == "true" ]] || ! jq -e '.structured_output' "$out_dir/raw.json" >/dev/null; then
  echo "::error::Claude error: $(jq -r '.result // "unknown"' "$out_dir/raw.json" | head -c 500)"
  exit 4
fi

jq '.structured_output' "$out_dir/raw.json" > "$out_dir/result.json"
