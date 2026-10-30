#!/bin/bash
# Transport evals for scripts/lib/kirunt.sh.
#
# Runs against a stubbed kiro-cli, so these need no real model access, no
# auth, and no tokens — the benchmark suite (run.sh --benchmark) covers the
# real round trip.
#
# Prints one PASS/FAIL line per check plus a machine-readable "## <pass> <fail>"
# trailer for run.sh. Runs as its own process so the stub cannot leak into
# the benchmark suite.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KIRUNT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

WORKDIR="$(mktemp -d)"
CAPTURED_ARGS="$WORKDIR/captured-args"

# The stub kiro-cli: records how it was invoked, then answers according to
# $STUB_MODE (set per-check below) so each check controls exactly what
# kirunt_invoke has to react to.
STUB_BIN="$WORKDIR/kiro-cli"
cat > "$STUB_BIN" << 'STUB_EOF'
#!/bin/bash
printf '%s\n' "$@" > "$CAPTURED_ARGS"
case "$STUB_MODE" in
  ok)
    printf '\x1b[38;5;141m> \x1b[0m- first line\n- second line\n'
    ;;
  ok-single-line)
    printf '\x1b[38;5;141m> \x1b[0mZZMARKERZZ\n'
    ;;
  empty)
    printf '\x1b[38;5;141m> \x1b[0m'
    ;;
  banner-noise)
    echo 'All tools are now trusted (!). Kiro will execute tools without asking for confirmation.' >&2
    printf '\x1b[38;5;141m> \x1b[0manswer\n'
    ;;
  fail)
    echo 'Error: model not available' >&2
    exit 1
    ;;
esac
STUB_EOF
chmod +x "$STUB_BIN"
export CAPTURED_ARGS
export STUB_MODE=""

# shellcheck source=../scripts/lib/kirunt.sh
. "$KIRUNT_DIR/scripts/lib/kirunt.sh"
KIRUNT_KIRO_CLI_BIN="$STUB_BIN"

PASSED=0
FAILED=0

check() {
  local name="$1" expected="$2" actual="$3" reason="$4"
  if [ "$expected" = "$actual" ]; then
    printf "  \033[32mPASS\033[0m  %-32s %s\n" "$name" "$reason"
    PASSED=$((PASSED + 1))
  else
    printf "  \033[31mFAIL\033[0m  %-32s expected=[%s] got=[%s]\n" "$name" "$expected" "$actual"
    FAILED=$((FAILED + 1))
  fi
}

message_file="$WORKDIR/message.txt"
printf 'line one\nline two\n' > "$message_file"

# ── Invocation & output cleanup ──

STUB_MODE=ok
check "answer-ansi-and-prefix-stripped" "- first line
- second line" "$(kirunt_invoke kirunt-bulk-reader "$message_file")" \
  "ANSI codes and leading '> ' echo are stripped from stdout"

STUB_MODE=ok-single-line
check "single-line-answer" "ZZMARKERZZ" "$(kirunt_invoke kirunt-bulk-reader "$message_file")" \
  "single-line answers survive cleanup"

STUB_MODE=ok
kirunt_invoke kirunt-bulk-reader "$message_file" >/dev/null
check "agent-flag-sent" "kirunt-bulk-reader" "$(grep -x -A1 -- '--agent' "$CAPTURED_ARGS" | tail -1)" \
  "the worker agent name is passed via --agent"

STUB_MODE=ok
kirunt_invoke "" "$message_file" >/dev/null
check "agent-flag-omitted-for-builtin" "n" "$(grep -qx -- '--agent' "$CAPTURED_ARGS" && echo y || echo n)" \
  "an empty agent name omits --agent so CLI V3 picks its built-in default agent"
check "model-flag-sent" "$KIRUNT_WORKER_MODEL" "$(grep -x -A1 -- '--model' "$CAPTURED_ARGS" | tail -1)" \
  "the worker model is passed via --model"
check "no-interactive-flag-sent" "y" "$(grep -qx -- '--no-interactive' "$CAPTURED_ARGS" && echo y || echo n)" \
  "headless mode is requested"
check "trust-all-tools-flag-sent" "y" "$(grep -qx -- '--trust-all-tools' "$CAPTURED_ARGS" && echo y || echo n)" \
  "tool approval cannot block on stdin (worker has no tools to approve anyway)"
check "message-sent" "line one
line two" "$(tail -2 "$CAPTURED_ARGS")" \
  "the message file's content is the final positional argument, verbatim"

# ── KIRUNT_WORKER_MODEL is just a shell variable kirunt_invoke reads ──
#
# kirunt_invoke has no idea whether KIRUNT_WORKER_MODEL came from
# config.json (the normal path) or was reassigned after sourcing — it just
# reads whatever the variable currently holds. This check isn't validating
# an env-var override feature (config.json is the sole source for that
# now); it's validating that kirunt_invoke reads the variable rather than
# a value captured at source time, which the fix-loop mechanics above rely
# on when tests reassign it directly.
( KIRUNT_WORKER_MODEL="a-different-model"
  kirunt_invoke kirunt-bulk-reader "$message_file" >/dev/null
  grep -x -A1 -- '--model' "$CAPTURED_ARGS" | tail -1 ) > "$WORKDIR/model-override-result"
check "worker-model-var-read-live-not-cached" "a-different-model" "$(cat "$WORKDIR/model-override-result")" \
  "kirunt_invoke reads KIRUNT_WORKER_MODEL live, not a value cached at source time"

# ── Stderr separation ──

STUB_MODE=banner-noise
check "stderr-noise-ignored" "answer" "$(kirunt_invoke kirunt-bulk-reader "$message_file" 2>/dev/null)" \
  "the trust-all-tools banner on stderr must not corrupt the stdout answer"

# ── Failure paths ──

STUB_MODE=fail
( kirunt_invoke kirunt-bulk-reader "$message_file" >/dev/null 2>&1 ) && rc=0 || rc=$?
check "nonzero-exit-fails" "1" "$rc" "a failed kiro-cli invocation is reported as an error, not swallowed"

STUB_MODE=empty
( kirunt_invoke kirunt-bulk-reader "$message_file" >/dev/null 2>&1 ) && rc=0 || rc=$?
check "empty-answer-fails" "1" "$rc" "an empty answer (after cleanup) is treated as a failure, not a blank success"

report=$(STUB_MODE=fail kirunt_invoke kirunt-bulk-reader "$message_file" 2>&1 >/dev/null)
case "$report" in
  *"Error: kirunt-bulk-reader"*"model not available"*)
    check "error-surfaces-stderr" "y" "y" "the underlying kiro-cli stderr is surfaced, not discarded" ;;
  *)
    check "error-surfaces-stderr" "y" "n" "the underlying kiro-cli stderr is surfaced, not discarded" ;;
esac

# ── Preflight ──

STUB_MODE=ok
if command -v jq >/dev/null 2>&1; then
  check "preflight-passes-when-tools-present" "0" "$(kirunt_preflight >/dev/null 2>&1; echo $?)" \
    "jq and the (stubbed) kiro-cli binary are both resolvable"
fi

( KIRUNT_KIRO_CLI_BIN="/nonexistent/kiro-cli-binary-xyz"
  kirunt_preflight >/dev/null 2>&1 ) && rc=0 || rc=$?
check "preflight-fails-when-binary-missing" "1" "$rc" \
  "a missing kiro-cli binary is caught before attempting delegation"

rm -rf "$WORKDIR"

echo "## $PASSED $FAILED"
[ "$FAILED" -gt 0 ] && exit 1
exit 0
