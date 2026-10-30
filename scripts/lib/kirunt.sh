#!/bin/bash
# Shared plumbing for kirunt's delegation scripts (bulk-read, code-write).
#
# Delegation goes through `kiro-cli chat --no-interactive`, pointed at a
# dedicated tool-less worker agent and a swappable worker model. No external
# CLI or service is required — everything runs against the same kiro-cli
# binary the caller is already using.
#
# Every delegation is one shot: each invocation is a fresh, non-interactive
# `kiro-cli chat` session with no memory of prior calls. Carrying context
# across calls would mean replaying it from this side, which for a file
# corpus is the exact cost this plugin exists to avoid. Ask again with the
# files instead.

# ---- config.json loading ------------------------------------------------
#
# All tunables below (worker model, timeout, min-lines threshold, feature
# flags, MCP-caller mode) load from config.json — a single JSON file, no
# env var overrides. This is deliberate: one file to edit, one place every
# consumer (hooks, scripts, evals) resolves the same values from, no
# environment-drift between a user's shell and what's actually in effect.
#
# Resolution order for the config file path itself:
#   1. $KIRUNT_CONFIG_PATH — internal test seam only. Lets evals point at a
#      throwaway config.json instead of mutating the real one. Never
#      documented as user-facing config; if you're a human editing
#      settings, edit config.json directly instead of setting this.
#   2. <bundle-root>/config.json — resolved relative to this file's own
#      location (scripts/lib/kirunt.sh), so it finds the right file both
#      in-repo and once installed under ~/.kiro/kirunt/config.json.
#
# If the file is missing or fails to parse as JSON, every tunable falls
# back to its hardcoded safe default below rather than aborting — a
# broken/missing config.json should degrade gracefully, not break every
# kirunt script and hook.
_KIRUNT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

kirunt_config_path() {
  if [ -n "${KIRUNT_CONFIG_PATH:-}" ]; then
    printf '%s' "$KIRUNT_CONFIG_PATH"
  else
    printf '%s' "$_KIRUNT_LIB_DIR/../../config.json"
  fi
}

_KIRUNT_CONFIG_FILE="$(kirunt_config_path)"

# Reads one key from config.json via jq. Prints empty string (not "null")
# on any failure — missing file, invalid JSON, or missing key — so callers
# can uniformly test for emptiness before falling back.
#
# Uses `if .[$k] == null then empty else .[$k] end` rather than the more
# common `.[$k] // empty` — the latter treats JSON `false` as falsy too,
# which would make an explicit "enable_x": false in config.json read back
# as empty (and then fall back to the "true" default below), silently
# ignoring the one value users are most likely to intentionally set.
_kirunt_config_get() {
  local key="$1" value
  [ -f "$_KIRUNT_CONFIG_FILE" ] || { printf ''; return; }
  value=$(jq -r --arg k "$key" 'if .[$k] == null then "" else .[$k] end' "$_KIRUNT_CONFIG_FILE" 2>/dev/null)
  printf '%s' "$value"
}

# The model used for delegated (worker-agent) calls. This is the ONE place
# that should need editing to swap the worker model — scripts and worker
# agent configs never hardcode a model name.
KIRUNT_WORKER_MODEL="$(_kirunt_config_get worker_model)"
[ -z "$KIRUNT_WORKER_MODEL" ] && KIRUNT_WORKER_MODEL="claude-haiku-4.5"

# Line count above which the read/bash hooks block and redirect to bulk-read.
# Also read directly by bulk-read/the hooks; kept here so every consumer
# resolves the same default in one place.
KIRUNT_MIN_LINES="$(_kirunt_config_get min_lines)"
case "$KIRUNT_MIN_LINES" in ''|*[!0-9]*) KIRUNT_MIN_LINES=350 ;; esac

# Ceiling for one worker invocation; large generations can take a while.
KIRUNT_TIMEOUT_SECONDS="$(_kirunt_config_get timeout_seconds)"
case "$KIRUNT_TIMEOUT_SECONDS" in ''|*[!0-9]*) KIRUNT_TIMEOUT_SECONDS=180 ;; esac

# Single authoritative switch for the bulk-reader capability. Read by:
#   - hooks/check-file-size   (skips blocking entirely when false)
#   - hooks/check-bash-read   (skips blocking entirely when false)
#   - scripts/bulk-read       (refuses to run when false)
# Keeping one flag for all three avoids the hook blocking a read while the
# delegation path that block exists to redirect to is itself disabled.
KIRUNT_ENABLE_BULK_READER="$(_kirunt_config_get enable_bulk_reader)"
case "$KIRUNT_ENABLE_BULK_READER" in
  [Ff][Aa][Ll][Ss][Ee]|0|no|No|NO) KIRUNT_ENABLE_BULK_READER=false ;;
  *) KIRUNT_ENABLE_BULK_READER=true ;;
esac

# Switch for the code-writer capability. Script-only: there is no hook
# enforcing code-writer use, so disabling this just makes the main agent
# fall back to writing code itself — no coordination needed.
KIRUNT_ENABLE_CODE_WRITER="$(_kirunt_config_get enable_code_writer)"
case "$KIRUNT_ENABLE_CODE_WRITER" in
  [Ff][Aa][Ll][Ss][Ee]|0|no|No|NO) KIRUNT_ENABLE_CODE_WRITER=false ;;
  *) KIRUNT_ENABLE_CODE_WRITER=true ;;
esac

# Switch for the mcp-caller capability. Script-only, same as code-writer:
# the main agent never lists any @server/tool entries in its own `tools`
# array, so there is nothing for a hook to intercept — omission from
# `tools` is what keeps MCP calls off the main agent's context by
# construction. Disabling this just means the main agent has no delegation
# path for MCP calls at all (it still can't call MCP tools directly).
KIRUNT_ENABLE_MCP_CALLER="$(_kirunt_config_get enable_mcp_caller)"
case "$KIRUNT_ENABLE_MCP_CALLER" in
  [Ff][Aa][Ll][Ss][Ee]|0|no|No|NO) KIRUNT_ENABLE_MCP_CALLER=false ;;
  *) KIRUNT_ENABLE_MCP_CALLER=true ;;
esac

# Which agent identity scripts/mcp-call delegates to. Two modes:
#
#   worker (default) — kirunt-mcp-caller, a dedicated custom agent
#     (agents/kirunt-mcp-caller.json) using includeMcpJson + @mcp to
#     auto-discover whatever MCP servers are configured. Verified working
#     on Kiro CLI V3 (2.36.0), where MCP tools load on demand. On very old
#     CLI 2.x builds (2.19.1) this path could not surface MCP tools for
#     custom agents in headless mode (upstream issue #5873); the V3
#     migration requires a newer CLI, so worker is the default again.
#
#   kiro-default — delegates to Kiro's built-in default agent. In CLI V3
#     built-in agents are selected by omitting --agent entirely; passing
#     --agent kiro_default errors with "agent not found". This mode is kept
#     for fallback/testing. kiro_default has no kirunt-specific prompt, so
#     the distillation instructions travel in the message body for that
#     call. The worker model (KIRUNT_WORKER_MODEL) is passed via --model
#     either way, so this mode still uses the cheap worker model.
KIRUNT_MCP_CALLER_MODE="$(_kirunt_config_get mcp_caller_mode)"
case "$KIRUNT_MCP_CALLER_MODE" in
  [Kk][Ii][Rr][Oo]-[Dd][Ee][Ff][Aa][Uu][Ll][Tt]) KIRUNT_MCP_CALLER_MODE=kiro-default ;;
  *) KIRUNT_MCP_CALLER_MODE=worker ;;
esac

# The kiro-cli binary to invoke for delegated calls. Override if the binary
# isn't on PATH under its default name.
KIRUNT_KIRO_CLI_BIN="${KIRUNT_KIRO_CLI_BIN:-kiro-cli}"

# mktemp with cleanup on script exit. Usage: kirunt_tmpfile <varname>
KIRUNT_TMPFILES=()
kirunt_tmpfile() {
  local f
  f=$(mktemp) || return 1
  KIRUNT_TMPFILES+=("$f")
  trap 'rm -f "${KIRUNT_TMPFILES[@]}"' EXIT
  printf -v "$1" '%s' "$f"
}

kirunt_preflight() {
  local missing=""
  command -v jq >/dev/null 2>&1 || missing=" jq"
  command -v "$KIRUNT_KIRO_CLI_BIN" >/dev/null 2>&1 || missing="$missing $KIRUNT_KIRO_CLI_BIN"

  if [ -n "$missing" ]; then
    echo "Error: missing required command(s):$missing" >&2
    echo "  jq       — brew install jq" >&2
    echo "  kiro-cli — https://kiro.dev, or set KIRUNT_KIRO_CLI_BIN" >&2
    return 1
  fi
  return 0
}

# Surfaces a failed worker invocation.
#   $1 label (e.g. "bulk-reader")
#   $2 combined stdout/stderr from the failed call
kirunt_report_error() {
  local label="$1" response="$2"
  echo "Error: $label: delegation failed" >&2
  if [ -n "$response" ]; then
    printf '%s\n' "$response" >&2
  fi
}

# Runs one ephemeral, non-interactive kiro-cli chat turn against a worker
# agent and prints the answer to stdout.
#   $1 worker agent name (e.g. "kirunt-bulk-reader"); empty = built-in
#      default agent, selected by omitting --agent (required by CLI V3)
#   $2 file holding the message/prompt to send
#
# Worker agents declare `"tools": []`, so --trust-all-tools has nothing to
# approve — it only exists to satisfy headless mode's requirement that tool
# approval never blocks on stdin.
kirunt_invoke() {
  local agent_name="$1" message_file="$2"
  local message stderr_file combined rc err clean
  local -a args

  message=$(cat "$message_file")

  args=(chat --no-interactive)
  [ -n "$agent_name" ] && args+=(--agent "$agent_name")
  args+=(--model "$KIRUNT_WORKER_MODEL" --trust-all-tools "$message")

  stderr_file=$(mktemp)
  combined=$("$KIRUNT_KIRO_CLI_BIN" "${args[@]}" 2>"$stderr_file")
  rc=$?
  err=$(cat "$stderr_file"; rm -f "$stderr_file")

  if [ "$rc" -ne 0 ]; then
    kirunt_report_error "${agent_name:-default}" "${combined:-$err}"
    return 1
  fi

  # stdout carries the answer prefixed with an ANSI-colored "> " prompt
  # echo; the trust-all-tools banner and the credits/time stats footer are
  # printed to stderr, not stdout, in headless mode. Strip ANSI escape
  # codes and the leading "> " marker to get a clean answer.
  clean=$(printf '%s' "$combined" | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' | sed -E 's/^> //')

  if [ -z "$clean" ]; then
    kirunt_report_error "${agent_name:-default}" "$err"
    echo "kiro-cli returned no output." >&2
    return 1
  fi

  printf '%s\n' "$clean"
}
