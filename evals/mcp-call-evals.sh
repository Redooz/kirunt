#!/bin/bash
# Argument-validation evals for scripts/mcp-call.
#
# Covers the script's own input handling (missing/conflicting flags,
# malformed JSON, disabled switch) against a stubbed kiro-cli — no live
# model access, no MCP servers, no auth required. The end-to-end delegation
# behavior (does the worker actually resolve an MCP tool) is
# covered by evals.json, which needs a live agent and MCP servers.
#
# Prints one PASS/FAIL line per check plus a machine-readable
# "## <pass> <fail>" trailer, same convention as transport-evals.sh.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KIRUNT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# Stub kiro-cli: never actually reached by the validation-failure checks
# below (they should all fail before invoking it), but a passing stub is
# provided for the one "valid call" happy-path check.
STUB_BIN="$WORKDIR/kiro-cli"
cat > "$STUB_BIN" << 'STUB_EOF'
#!/bin/bash
printf '\x1b[38;5;141m> \x1b[0mstub answer\n'
STUB_EOF
chmod +x "$STUB_BIN"

export KIRUNT_KIRO_CLI_BIN="$STUB_BIN"

# Writes a temp config.json with the given overrides (jq --argjson pairs)
# merged onto the real defaults, and prints its path. Tunables no longer
# read from env vars — KIRUNT_CONFIG_PATH is the only way to point a call
# at a non-default config, so every check below that used to set
# KIRUNT_ENABLE_MCP_CALLER/KIRUNT_MCP_CALLER_MODE/KIRUNT_WORKER_MODEL via
# `env VAR=...` now builds one of these instead.
write_config() {
  local out="$1"; shift
  jq -n \
    --arg worker_model "${WORKER_MODEL:-claude-haiku-4.5}" \
    --argjson min_lines 350 \
    --argjson timeout_seconds 180 \
    --argjson enable_bulk_reader true \
    --argjson enable_code_writer true \
    --argjson enable_mcp_caller "${ENABLE_MCP_CALLER:-true}" \
    --arg mcp_caller_mode "${MCP_CALLER_MODE:-worker}" \
    '{worker_model: $worker_model, min_lines: $min_lines, timeout_seconds: $timeout_seconds, enable_bulk_reader: $enable_bulk_reader, enable_code_writer: $enable_code_writer, enable_mcp_caller: $enable_mcp_caller, mcp_caller_mode: $mcp_caller_mode}' \
    > "$out"
}

DEFAULT_CONFIG="$WORKDIR/default-config.json"
write_config "$DEFAULT_CONFIG"
export KIRUNT_CONFIG_PATH="$DEFAULT_CONFIG"

PASSED=0
FAILED=0

check_exit() {
  local name="$1" expected_rc="$2" reason="$3"
  shift 3
  local rc
  "$@" >/dev/null 2>"$WORKDIR/stderr"
  rc=$?
  if [ "$rc" = "$expected_rc" ]; then
    printf "  \033[32mPASS\033[0m  %-38s %s\n" "$name" "$reason"
    PASSED=$((PASSED + 1))
  else
    printf "  \033[31mFAIL\033[0m  %-38s expected_rc=%s got_rc=%s\n" "$name" "$expected_rc" "$rc"
    FAILED=$((FAILED + 1))
  fi
}

check() {
  local name="$1" expected="$2" actual="$3" reason="$4"
  if [ "$expected" = "$actual" ]; then
    printf "  \033[32mPASS\033[0m  %-38s %s\n" "$name" "$reason"
    PASSED=$((PASSED + 1))
  else
    printf "  \033[31mFAIL\033[0m  %-38s expected=[%s] got=[%s]\n" "$name" "$expected" "$actual"
    FAILED=$((FAILED + 1))
  fi
}

MCP_CALL="$KIRUNT_DIR/scripts/mcp-call"

check_exit "missing-question" 1 \
  "--question is required" \
  "$MCP_CALL" --tool "@fetch/fetch"

check_exit "args-without-tool" 1 \
  "--args requires --tool — nothing to call arguments against" \
  "$MCP_CALL" --question "q" --args '{"x":1}'

check_exit "args-file-without-tool" 1 \
  "--args-file requires --tool, same as --args" \
  "$MCP_CALL" --question "q" --args-file "$WORKDIR/nonexistent.json"

check_exit "args-and-args-file-both" 1 \
  "--args and --args-file are mutually exclusive" \
  "$MCP_CALL" --question "q" --tool "@fetch/fetch" --args '{}' --args-file "$WORKDIR/x.json"

check_exit "args-file-missing" 1 \
  "a nonexistent --args-file path is caught before invoking the worker" \
  "$MCP_CALL" --question "q" --tool "@fetch/fetch" --args-file "$WORKDIR/does-not-exist.json"

check_exit "malformed-json-args" 1 \
  "invalid JSON in --args is rejected before invoking the worker" \
  "$MCP_CALL" --question "q" --tool "@fetch/fetch" --args '{not json'

echo '{"url":"https://example.com"}' > "$WORKDIR/valid-args.json"
check_exit "malformed-json-args-file" 1 \
  "invalid JSON in --args-file is rejected the same way as --args" \
  bash -c "echo '{not json' > '$WORKDIR/bad.json' && '$MCP_CALL' --question q --tool '@fetch/fetch' --args-file '$WORKDIR/bad.json'"

DISABLED_MCP_CALLER_CONFIG="$WORKDIR/disabled-mcp-caller-config.json"
ENABLE_MCP_CALLER=false write_config "$DISABLED_MCP_CALLER_CONFIG"
check_exit "disabled-switch" 1 \
  "enable_mcp_caller=false (config.json) refuses to run, mirroring bulk-read/code-write" \
  env KIRUNT_CONFIG_PATH="$DISABLED_MCP_CALLER_CONFIG" "$MCP_CALL" --question "q"

check_exit "question-only-happy-path" 0 \
  "a bare --question with no --tool delegates fine (worker resolves the tool itself)" \
  "$MCP_CALL" --question "q"

check_exit "tool-with-valid-args-happy-path" 0 \
  "--tool with valid inline --args delegates fine" \
  "$MCP_CALL" --question "q" --tool "@fetch/fetch" --args '{"url":"https://example.com"}'

check_exit "tool-with-valid-args-file-happy-path" 0 \
  "--tool with a valid --args-file delegates fine" \
  "$MCP_CALL" --question "q" --tool "@fetch/fetch" --args-file "$WORKDIR/valid-args.json"

# ── KIRUNT_MCP_CALLER_MODE switch ──
#
# Confirms mcp-call targets the right agent name for each mode. The stub
# kiro-cli records its args regardless of agent name, so this checks the
# --agent value it was actually invoked with rather than end-to-end MCP
# resolution (that needs a live kiro-cli + real/fixture MCP servers, see
# evals.json for the end-to-end scenarios).
CAPTURED_ARGS_FILE="$WORKDIR/captured-args"
cat > "$STUB_BIN" << STUB_EOF2
#!/bin/bash
printf '%s\n' "\$@" > "$CAPTURED_ARGS_FILE"
printf '\x1b[38;5;141m> \x1b[0mstub answer\n'
STUB_EOF2
chmod +x "$STUB_BIN"

WORKER_MODE_CONFIG="$WORKDIR/worker-mode-config.json"
MCP_CALLER_MODE=worker write_config "$WORKER_MODE_CONFIG"
env KIRUNT_CONFIG_PATH="$WORKER_MODE_CONFIG" "$MCP_CALL" --question "q" >/dev/null 2>&1
check "worker-mode-targets-worker-agent" "kirunt-mcp-caller" "$(grep -x -A1 -- '--agent' "$CAPTURED_ARGS_FILE" | tail -1)" \
  "default/worker mode delegates to the kirunt-mcp-caller custom agent"

KIRO_DEFAULT_MODE_CONFIG="$WORKDIR/kiro-default-mode-config.json"
MCP_CALLER_MODE=kiro-default write_config "$KIRO_DEFAULT_MODE_CONFIG"
env KIRUNT_CONFIG_PATH="$KIRO_DEFAULT_MODE_CONFIG" "$MCP_CALL" --question "q" >/dev/null 2>&1
check "kiro-default-mode-omits-agent-flag" "n" "$(grep -qx -- '--agent' "$CAPTURED_ARGS_FILE" && echo y || echo n)" \
  "kiro-default mode lets kiro-cli select its built-in default by omitting --agent (CLI V3)"

env KIRUNT_CONFIG_PATH="$KIRO_DEFAULT_MODE_CONFIG" "$MCP_CALL" --question "q" >/dev/null 2>&1
model_used="$(grep -x -A1 -- '--model' "$CAPTURED_ARGS_FILE" | tail -1)"
check "kiro-default-mode-uses-worker-model" "claude-haiku-4.5" "$model_used" \
  "kiro-default mode still passes --model with the cheap worker model (default), not the main session's model"

KIRO_DEFAULT_CUSTOM_MODEL_CONFIG="$WORKDIR/kiro-default-custom-model-config.json"
MCP_CALLER_MODE=kiro-default WORKER_MODEL=a-different-worker-model write_config "$KIRO_DEFAULT_CUSTOM_MODEL_CONFIG"
env KIRUNT_CONFIG_PATH="$KIRO_DEFAULT_CUSTOM_MODEL_CONFIG" "$MCP_CALL" --question "q" >/dev/null 2>&1
model_used="$(grep -x -A1 -- '--model' "$CAPTURED_ARGS_FILE" | tail -1)"
check "kiro-default-mode-respects-worker-model-override" "a-different-worker-model" "$model_used" \
  "worker_model override in config.json propagates to kiro-default mode the same as worker mode"

INVALID_MODE_CONFIG="$WORKDIR/invalid-mode-config.json"
MCP_CALLER_MODE=invalid-value write_config "$INVALID_MODE_CONFIG"
env KIRUNT_CONFIG_PATH="$INVALID_MODE_CONFIG" "$MCP_CALL" --question "q" >/dev/null 2>&1
check "invalid-mode-falls-back-to-worker" "kirunt-mcp-caller" "$(grep -x -A1 -- '--agent' "$CAPTURED_ARGS_FILE" | tail -1)" \
  "an unrecognized mcp_caller_mode value in config.json falls back to worker mode, not a silent misconfiguration"

echo "## $PASSED $FAILED"
[ "$FAILED" -gt 0 ] && exit 1
exit 0
