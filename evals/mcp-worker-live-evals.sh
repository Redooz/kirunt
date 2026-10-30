#!/bin/bash
# Live evals for kirunt-mcp-caller's tool-use judgment.
#
# These need a real kiro-cli + model round trip and use the checked-in
# fixture MCP server, so they are opt-in (bash evals/run.sh --mcp-live)
# rather than part of the offline suite.
#
# Cases:
#   1. A lookup request with a generic "use your tools" hint (no mention of
#      MCP) must load and call the fixture get_env tool.
#   2. A self-contained arithmetic question must be answered directly,
#      with no MCP tool call.
#   3. An explicit --tool call must call the known fixture tool.
#
# Prints one PASS/FAIL line per check plus a machine-readable
# "## <pass> <fail>" trailer for run.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KIRUNT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE_SERVER="$SCRIPT_DIR/fixtures/mcp-fixture-server.js"
NONCE="kirunt-live-nonce-9f3c"

PASSED=0
FAILED=0

check() {
  local name="$1" expected="$2" actual="$3" reason="$4"
  if [ "$expected" = "$actual" ]; then
    printf "  \033[32mPASS\033[0m  %-38s %s\n" "$name" "$reason"
    PASSED=$((PASSED + 1))
  else
    printf "  \033[31mFAIL\033[0m  %-38s expected=[%s] actual=[%s]\n" "$name" "$expected" "$actual"
    FAILED=$((FAILED + 1))
  fi
}

if ! command -v kiro-cli >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! command -v node >/dev/null 2>&1; then
  echo "  (skipped: kiro-cli, jq, and node are required for live MCP evals)"
  echo "## 0 0"
  exit 0
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
CALL_LOG="$WORKDIR/mcp-calls.log"
CONFIG="$WORKDIR/config.json"

jq '.worker_model="claude-haiku-4.5" | .mcp_caller_mode="worker" | .enable_mcp_caller=true' \
  "$KIRUNT_DIR/config.json" > "$CONFIG"

mkdir -p "$WORKDIR/.kiro/settings"
jq -n \
  --arg server "$FIXTURE_SERVER" \
  --arg log "$CALL_LOG" \
  --arg nonce "$NONCE" \
  '{mcpServers: {"kirunt-live-fixture": {
      command: "node",
      args: [$server],
      env: {KIRUNT_TEST_NONCE: $nonce, KIRUNT_FIXTURE_LOG: $log},
      disabled: false
    }}}' > "$WORKDIR/.kiro/settings/mcp.json"

run_mcp_call() {
  ( cd "$WORKDIR" && KIRUNT_CONFIG_PATH="$CONFIG" "$KIRUNT_DIR/scripts/mcp-call" "$@" )
}

echo ""
echo "MCP worker live behavior (real kiro-cli + fixture MCP server)"
echo "────────────────────────────────────────────────────────────────"

# ── 1. Should look up information with MCP when a lookup is needed ──
rm -f "$CALL_LOG"
output=$(run_mcp_call --question "Use whatever tools you have available to look up the runtime environment and tell me the exact value of KIRUNT_TEST_NONCE." 2>&1)
rc=$?
case "$output" in
  *"$NONCE"*) found=yes ;;
  *) found=no ;;
esac
case "$(cat "$CALL_LOG" 2>/dev/null)" in
  *'"tool":"get_env"'*) called=yes ;;
  *) called=no ;;
esac
check "lookup-uses-mcp" "yes" "$found" "a lookup request with a generic tools hint returns the MCP value"
check "lookup-invokes-fixture-tool" "yes" "$called" "the worker actually calls the fixture MCP tool"
check "lookup-exit-zero" "0" "$rc" "the live mcp-call exits successfully"

# ── 2. Should NOT call MCP for a self-contained question ──
rm -f "$CALL_LOG"
output=$(run_mcp_call --question "What is 17 + 25? Reply with just the number." 2>&1)
rc=$?
case "$output" in
  *42*) answered=yes ;;
  *) answered=no ;;
esac
calls=$(cat "$CALL_LOG" 2>/dev/null)
[ -z "$calls" ] && called=no || called=yes
check "simple-question-answered" "yes" "$answered" "self-contained arithmetic is answered directly"
check "simple-question-no-mcp" "no" "$called" "no MCP tool is called for a self-contained question"
check "simple-question-exit-zero" "0" "$rc" "the live mcp-call exits successfully"

# ── 3. Explicit --tool call targets the known fixture tool ──
rm -f "$CALL_LOG"
output=$(run_mcp_call --tool "@kirunt-live-fixture/get_env" --args "{\"name\":\"KIRUNT_TEST_NONCE\"}" --question "Report the exact value." 2>&1)
rc=$?
case "$output" in
  *"$NONCE"*) found=yes ;;
  *) found=no ;;
esac
case "$(cat "$CALL_LOG" 2>/dev/null)" in
  *'"tool":"get_env"'*) called=yes ;;
  *) called=no ;;
esac
check "explicit-tool-returns-value" "yes" "$found" "an explicit --tool call returns the MCP value"
check "explicit-tool-invokes-fixture" "yes" "$called" "an explicit --tool call reaches the fixture MCP server"
check "explicit-tool-exit-zero" "0" "$rc" "the live mcp-call exits successfully"

echo ""
echo "## $PASSED $FAILED"
[ "$FAILED" -gt 0 ] && exit 1
exit 0
