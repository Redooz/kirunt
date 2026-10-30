#!/bin/bash
# Evals for config.json loading in scripts/lib/kirunt.sh.
#
# Covers: defaults load correctly from the real config.json, a custom
# config.json (via the internal KIRUNT_CONFIG_PATH test seam) overrides
# every value, malformed/missing config falls back to hardcoded safe
# defaults instead of crashing, and numeric/boolean validation still
# rejects garbage the same way the old env-var version did.
#
# Prints one PASS/FAIL line per check plus a machine-readable
# "## <pass> <fail>" trailer, same convention as transport-evals.sh.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KIRUNT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

PASSED=0
FAILED=0

check() {
  local name="$1" expected="$2" actual="$3" reason="$4"
  if [ "$expected" = "$actual" ]; then
    printf "  \033[32mPASS\033[0m  %-42s %s\n" "$name" "$reason"
    PASSED=$((PASSED + 1))
  else
    printf "  \033[31mFAIL\033[0m  %-42s expected=%s actual=%s\n" "$name" "$expected" "$actual"
    FAILED=$((FAILED + 1))
  fi
}

echo "config-evals: kirunt.sh config.json loading"
echo ""

# --- real config.json loads as-is ---------------------------------------
(
  unset KIRUNT_CONFIG_PATH
  # shellcheck source=../scripts/lib/kirunt.sh
  . "$KIRUNT_DIR/scripts/lib/kirunt.sh"
  echo "$KIRUNT_WORKER_MODEL|$KIRUNT_MIN_LINES|$KIRUNT_TIMEOUT_SECONDS|$KIRUNT_ENABLE_BULK_READER|$KIRUNT_ENABLE_CODE_WRITER|$KIRUNT_ENABLE_MCP_CALLER|$KIRUNT_MCP_CALLER_MODE"
) > "$WORKDIR/real-defaults.out"
check "real-config-loads" "claude-haiku-4.5|350|180|true|true|true|worker" "$(cat "$WORKDIR/real-defaults.out")" \
  "Real config.json values load into the expected shell vars"

# --- custom config.json (test seam) overrides every value ---------------
cat > "$WORKDIR/custom-config.json" << 'EOF'
{
  "worker_model": "test-model-x",
  "min_lines": 42,
  "timeout_seconds": 99,
  "enable_bulk_reader": false,
  "enable_code_writer": false,
  "enable_mcp_caller": false,
  "mcp_caller_mode": "kiro-default"
}
EOF
(
  export KIRUNT_CONFIG_PATH="$WORKDIR/custom-config.json"
  # shellcheck source=../scripts/lib/kirunt.sh
  . "$KIRUNT_DIR/scripts/lib/kirunt.sh"
  echo "$KIRUNT_WORKER_MODEL|$KIRUNT_MIN_LINES|$KIRUNT_TIMEOUT_SECONDS|$KIRUNT_ENABLE_BULK_READER|$KIRUNT_ENABLE_CODE_WRITER|$KIRUNT_ENABLE_MCP_CALLER|$KIRUNT_MCP_CALLER_MODE"
) > "$WORKDIR/custom.out"
check "custom-config-overrides" "test-model-x|42|99|false|false|false|kiro-default" "$(cat "$WORKDIR/custom.out")" \
  "Custom config.json (via KIRUNT_CONFIG_PATH test seam) overrides every tunable"

# --- missing config.json falls back to hardcoded safe defaults ----------
(
  export KIRUNT_CONFIG_PATH="$WORKDIR/does-not-exist.json"
  # shellcheck source=../scripts/lib/kirunt.sh
  . "$KIRUNT_DIR/scripts/lib/kirunt.sh"
  echo "$KIRUNT_WORKER_MODEL|$KIRUNT_MIN_LINES|$KIRUNT_TIMEOUT_SECONDS|$KIRUNT_ENABLE_BULK_READER|$KIRUNT_ENABLE_CODE_WRITER|$KIRUNT_ENABLE_MCP_CALLER|$KIRUNT_MCP_CALLER_MODE"
) > "$WORKDIR/missing.out"
check "missing-config-falls-back" "claude-haiku-4.5|350|180|true|true|true|worker" "$(cat "$WORKDIR/missing.out")" \
  "Missing config.json falls back to hardcoded safe defaults, does not crash"

# --- malformed config.json falls back to hardcoded safe defaults --------
echo '{ not valid json' > "$WORKDIR/broken-config.json"
(
  export KIRUNT_CONFIG_PATH="$WORKDIR/broken-config.json"
  # shellcheck source=../scripts/lib/kirunt.sh
  . "$KIRUNT_DIR/scripts/lib/kirunt.sh"
  echo "$KIRUNT_WORKER_MODEL|$KIRUNT_MIN_LINES|$KIRUNT_TIMEOUT_SECONDS|$KIRUNT_ENABLE_BULK_READER|$KIRUNT_ENABLE_CODE_WRITER|$KIRUNT_ENABLE_MCP_CALLER|$KIRUNT_MCP_CALLER_MODE"
) > "$WORKDIR/broken.out"
check "malformed-config-falls-back" "claude-haiku-4.5|350|180|true|true|true|worker" "$(cat "$WORKDIR/broken.out")" \
  "Malformed config.json falls back to hardcoded safe defaults, does not crash"

# --- non-numeric min_lines/timeout_seconds fall back individually -------
cat > "$WORKDIR/bad-numbers.json" << 'EOF'
{
  "worker_model": "test-model-y",
  "min_lines": "not-a-number",
  "timeout_seconds": "also-not-a-number",
  "enable_bulk_reader": true,
  "enable_code_writer": true,
  "enable_mcp_caller": true,
  "mcp_caller_mode": "worker"
}
EOF
(
  export KIRUNT_CONFIG_PATH="$WORKDIR/bad-numbers.json"
  # shellcheck source=../scripts/lib/kirunt.sh
  . "$KIRUNT_DIR/scripts/lib/kirunt.sh"
  echo "$KIRUNT_WORKER_MODEL|$KIRUNT_MIN_LINES|$KIRUNT_TIMEOUT_SECONDS"
) > "$WORKDIR/bad-numbers.out"
check "bad-numbers-fall-back" "test-model-y|350|180" "$(cat "$WORKDIR/bad-numbers.out")" \
  "Non-numeric min_lines/timeout_seconds fall back to 350/180, other fields still load"

# --- unrecognized mcp_caller_mode falls back to 'worker' -----------------
cat > "$WORKDIR/bad-mode.json" << 'EOF'
{
  "worker_model": "claude-haiku-4.5",
  "min_lines": 350,
  "timeout_seconds": 180,
  "enable_bulk_reader": true,
  "enable_code_writer": true,
  "enable_mcp_caller": true,
  "mcp_caller_mode": "something-else"
}
EOF
(
  export KIRUNT_CONFIG_PATH="$WORKDIR/bad-mode.json"
  # shellcheck source=../scripts/lib/kirunt.sh
  . "$KIRUNT_DIR/scripts/lib/kirunt.sh"
  echo "$KIRUNT_MCP_CALLER_MODE"
) > "$WORKDIR/bad-mode.out"
check "bad-mode-falls-back-to-worker" "worker" "$(cat "$WORKDIR/bad-mode.out")" \
  "Unrecognized mcp_caller_mode falls back to 'worker'"

# --- KIRUNT_KIRO_CLI_BIN env var still works (unchanged, not in config.json) ---
(
  export KIRUNT_KIRO_CLI_BIN="/tmp/fake-kiro-cli"
  # shellcheck source=../scripts/lib/kirunt.sh
  . "$KIRUNT_DIR/scripts/lib/kirunt.sh"
  echo "$KIRUNT_KIRO_CLI_BIN"
) > "$WORKDIR/bin-override.out"
check "kiro-cli-bin-env-var-unchanged" "/tmp/fake-kiro-cli" "$(cat "$WORKDIR/bin-override.out")" \
  "KIRUNT_KIRO_CLI_BIN remains an env var, untouched by the config.json migration"

echo ""
echo "## $PASSED $FAILED"
[ "$FAILED" -eq 0 ]
