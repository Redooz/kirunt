#!/bin/bash
# Test runner for kirunt evals: hook routing decisions + token savings benchmarks
#
# Usage:
#   bash evals/run.sh                    # hooks + transport (no live model access needed)
#   bash evals/run.sh --benchmark        # + chars/4 token savings estimate (needs kiro-cli + model access)
#   bash evals/run.sh --context-benchmark  # + real context-window delta cross-check (see evals/context-benchmark.sh)
#   bash evals/run.sh --mcp-live         # + live MCP worker tool-use evals (needs kiro-cli + model access)
#   bash evals/run.sh --all              # every offline suite except live/context benchmarks

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KIRUNT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES="$SCRIPT_DIR/.fixtures"
BENCHMARKS="$SCRIPT_DIR/benchmarks.json"
PASSED=0
FAILED=0
TOTAL=0
RUN_BENCHMARK=false
RUN_CONTEXT_BENCHMARK=false
RUN_MCP_LIVE=false

for arg in "$@"; do
  case "$arg" in
    --benchmark)         RUN_BENCHMARK=true ;;
    --context-benchmark) RUN_CONTEXT_BENCHMARK=true ;;
    --mcp-live)          RUN_MCP_LIVE=true ;;
    --all)               RUN_BENCHMARK=true ;;
  esac
done

generate_fixture() {
  local path="$1" lines="$2"
  if [ "$lines" -eq 0 ]; then
    touch "$path"
  else
    seq 1 "$lines" | awk '{print "line "NR}' > "$path"
  fi
}

setup_fixtures() {
  local evals_file="$1"
  rm -rf "$FIXTURES"
  mkdir -p "$FIXTURES"

  local count
  count=$(jq '.evals | length' "$evals_file")

  for ((i = 0; i < count; i++)); do
    local fixture
    fixture=$(jq -r ".evals[$i].fixture" "$evals_file")
    [ "$fixture" = "null" ] && continue

    local lines
    lines=$(jq -r ".evals[$i].fixture.lines" "$evals_file")

    # Read hook evals use V2 tool_input.operations[0].path or the V3
    # tool_input.path; bash hook evals use tool_input.command (path is the
    # first non-flag arg). A relative path is resolved against the eval's
    # optional cwd (V3 events carry one).
    local input_path input_cwd fixture_path
    input_path=$(jq -r ".evals[$i].input.tool_input.operations[0].path // empty" "$evals_file")
    if [ -z "$input_path" ]; then
      input_path=$(jq -r ".evals[$i].input.tool_input.path // empty" "$evals_file")
    fi
    if [ -z "$input_path" ]; then
      input_path=$(jq -r ".evals[$i].input.tool_input.command // empty" "$evals_file" | sed -E 's/^(cat|head|tail|less|more) +(-[^ ]+ +)*//' | sed 's/ .*//' | tr -d '"'"'")
    fi
    input_path=$(echo "$input_path" | sed "s|{{FIXTURES}}|$FIXTURES|")

    input_cwd=$(jq -r ".evals[$i].input.cwd // empty" "$evals_file" | sed "s|{{FIXTURES}}|$FIXTURES|")
    case "$input_path" in
      /*) fixture_path="$input_path" ;;
      "") fixture_path="" ;;
      *)
        if [ -n "$input_cwd" ]; then
          mkdir -p "$input_cwd"
          fixture_path="$input_cwd/$input_path"
        else
          fixture_path=""
        fi
        ;;
    esac

    [ -n "$fixture_path" ] && generate_fixture "$fixture_path" "$lines"

    # A few cases (multi-op-second-offending) also declare extra_fixture
    # entries for additional files referenced by earlier operations in the
    # same batch.
    local extra_keys
    extra_keys=$(jq -r ".evals[$i].extra_fixture // {} | keys[]?" "$evals_file")
    for k in $extra_keys; do
      local v
      v=$(jq -r --arg k "$k" ".evals[$i].extra_fixture[\$k]" "$evals_file")
      generate_fixture "$FIXTURES/$k" "$v"
    done
  done
}

run_eval() {
  local hook="$1" name="$2" input="$3" expected="$4" reason="$5" env_json="$6"
  TOTAL=$((TOTAL + 1))

  local actual input_cwd
  input_cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)

  if [ -n "$env_json" ] && [ "$env_json" != "null" ] && [ "$env_json" != "{}" ]; then
    # Eval fixtures express overrides as KIRUNT_* env var names (kept as-is
    # in hook-evals.json/bash-hook-evals.json for readability — they read
    # as "what used to be an env var"). Tunables no longer respond to env
    # vars, so translate the handful of keys these fixtures use into a
    # throwaway config.json and point the hook at it via KIRUNT_CONFIG_PATH
    # instead of exporting the (now inert) env vars directly.
    local config_file
    config_file=$(mktemp)
    jq -n \
      --arg worker_model "$(echo "$env_json" | jq -r '.KIRUNT_WORKER_MODEL // "claude-haiku-4.5"')" \
      --arg min_lines "$(echo "$env_json" | jq -r '.KIRUNT_MIN_LINES // "350"')" \
      --arg timeout_seconds "$(echo "$env_json" | jq -r '.KIRUNT_TIMEOUT_SECONDS // "180"')" \
      --arg enable_bulk_reader "$(echo "$env_json" | jq -r '.KIRUNT_ENABLE_BULK_READER // "true"')" \
      --arg enable_code_writer "$(echo "$env_json" | jq -r '.KIRUNT_ENABLE_CODE_WRITER // "true"')" \
      --arg enable_mcp_caller "$(echo "$env_json" | jq -r '.KIRUNT_ENABLE_MCP_CALLER // "true"')" \
      --arg mcp_caller_mode "$(echo "$env_json" | jq -r '.KIRUNT_MCP_CALLER_MODE // "worker"')" \
      '{worker_model: $worker_model, min_lines: $min_lines, timeout_seconds: $timeout_seconds, enable_bulk_reader: $enable_bulk_reader, enable_code_writer: $enable_code_writer, enable_mcp_caller: $enable_mcp_caller, mcp_caller_mode: $mcp_caller_mode}' \
      > "$config_file"
    set +e
    if [ -n "$input_cwd" ]; then
      ( cd "$input_cwd" && echo "$input" | env KIRUNT_CONFIG_PATH="$config_file" bash "$hook" >/dev/null 2>&1 )
    else
      echo "$input" | env KIRUNT_CONFIG_PATH="$config_file" bash "$hook" >/dev/null 2>&1
    fi
    actual=$?
    set -e
    rm -f "$config_file"
  else
    set +e
    if [ -n "$input_cwd" ]; then
      ( cd "$input_cwd" && echo "$input" | bash "$hook" >/dev/null 2>&1 )
    else
      echo "$input" | bash "$hook" >/dev/null 2>&1
    fi
    actual=$?
    set -e
  fi

  if [ "$actual" = "$expected" ]; then
    printf "  \033[32mPASS\033[0m  %-30s %s\n" "$name" "$reason"
    PASSED=$((PASSED + 1))
  else
    printf "  \033[31mFAIL\033[0m  %-30s expected=%s got=%s\n" "$name" "$expected" "$actual"
    FAILED=$((FAILED + 1))
  fi
}

run_suite() {
  local hook="$1" evals_file="$2" label="$3"

  setup_fixtures "$evals_file"

  echo ""
  echo "$label"
  echo "────────────────────────────────────────────────────────────────"

  local count
  count=$(jq '.evals | length' "$evals_file")

  for ((i = 0; i < count; i++)); do
    local name expected reason input
    name=$(jq -r ".evals[$i].name" "$evals_file")
    expected=$(jq -r ".evals[$i].expected_exit" "$evals_file")
    reason=$(jq -r ".evals[$i].reason" "$evals_file")
    input=$(jq -c ".evals[$i].input" "$evals_file" | sed "s|{{FIXTURES}}|$FIXTURES|g")

    local env_json
    env_json=$(jq -c ".evals[$i].env // {}" "$evals_file")
    run_eval "$hook" "$name" "$input" "$expected" "$reason" "$env_json"
  done

  rm -rf "$FIXTURES"
}

# ── Transport suite ──

# Runs as a child process: the suite stubs kiro-cli, and that stub must not
# leak into the benchmarks below, which need the real one.
run_transport_suite() {
  echo ""
  echo "Transport (scripts/lib/kirunt.sh, stubbed kiro-cli)"
  echo "────────────────────────────────────────────────────────────────"

  local output counts p f
  output=$(bash "$SCRIPT_DIR/transport-evals.sh" 2>&1) || true

  printf '%s\n' "$output" | grep -v '^## ' || true
  counts=$(printf '%s\n' "$output" | grep '^## ' | tail -1 || true)
  p=$(printf '%s' "$counts" | awk '{print $2}')
  f=$(printf '%s' "$counts" | awk '{print $3}')

  if [ -z "$p" ]; then
    printf "  \033[31mFAIL\033[0m  %-32s suite did not report results\n" "transport-evals"
    FAILED=$((FAILED + 1))
    TOTAL=$((TOTAL + 1))
    return
  fi

  PASSED=$((PASSED + p))
  FAILED=$((FAILED + f))
  TOTAL=$((TOTAL + p + f))
}

# ── MCP-call argument validation suite ──

# Runs as a child process, same reasoning as the transport suite: it stubs
# kiro-cli and that stub must not leak into other suites.
run_mcp_call_suite() {
  echo ""
  echo "MCP-call argument validation (scripts/mcp-call, stubbed kiro-cli)"
  echo "────────────────────────────────────────────────────────────────"

  local output counts p f
  output=$(bash "$SCRIPT_DIR/mcp-call-evals.sh" 2>&1) || true

  printf '%s\n' "$output" | grep -v '^## ' || true
  counts=$(printf '%s\n' "$output" | grep '^## ' | tail -1 || true)
  p=$(printf '%s' "$counts" | awk '{print $2}')
  f=$(printf '%s' "$counts" | awk '{print $3}')

  if [ -z "$p" ]; then
    printf "  \033[31mFAIL\033[0m  %-32s suite did not report results\n" "mcp-call-evals"
    FAILED=$((FAILED + 1))
    TOTAL=$((TOTAL + 1))
    return
  fi

  PASSED=$((PASSED + p))
  FAILED=$((FAILED + f))
  TOTAL=$((TOTAL + p + f))
}

# ── Live MCP-worker behavior suite ──

# Runs as a child process because it needs a real model round trip and a
# temporary fixture MCP server; keep it out of the offline suite.
run_mcp_live_suite() {
  local output counts p f
  output=$(bash "$SCRIPT_DIR/mcp-worker-live-evals.sh" 2>&1) || true

  printf '%s\n' "$output" | grep -v '^## ' || true
  if printf '%s\n' "$output" | grep -q '(skipped:'; then
    return
  fi

  counts=$(printf '%s\n' "$output" | grep '^## ' | tail -1 || true)
  p=$(printf '%s' "$counts" | awk '{print $2}')
  f=$(printf '%s' "$counts" | awk '{print $3}')

  if [ -z "$p" ]; then
    printf "  \033[31mFAIL\033[0m  %-32s suite did not report results\n" "mcp-worker-live-evals"
    FAILED=$((FAILED + 1))
    TOTAL=$((TOTAL + 1))
    return
  fi

  PASSED=$((PASSED + p))
  FAILED=$((FAILED + f))
  TOTAL=$((TOTAL + p + f))
}

# ── Benchmark helpers ──

token_estimate() {
  echo $(( (${#1} + 3) / 4 ))
}

run_benchmark_bulk_read() {
  local idx="$1"
  local question corpus

  question=$(jq -r ".benchmarks[$idx].question" "$BENCHMARKS")
  corpus=""
  local paths_args=()

  while IFS= read -r p; do
    local full="$SCRIPT_DIR/$p"
    paths_args+=("$full")
    corpus="$corpus$(cat "$full")"
  done < <(jq -r ".benchmarks[$idx].paths[]" "$BENCHMARKS")

  local without_tokens
  without_tokens=$(token_estimate "$corpus")

  local response
  if ! response=$("$KIRUNT_DIR/scripts/bulk-read" --question "$question" --paths "${paths_args[@]}" 2>/dev/null); then
    echo "0 0 0 fail"
    return
  fi
  [ -z "$response" ] && { echo "0 0 0 fail"; return; }

  local with_tokens
  with_tokens=$(token_estimate "$response")

  local total_lines=0
  while IFS= read -r p; do
    local lines
    lines=$(wc -l < "$SCRIPT_DIR/$p" | tr -d ' ')
    total_lines=$(( total_lines + lines ))
  done < <(jq -r ".benchmarks[$idx].paths[]" "$BENCHMARKS")

  echo "$total_lines $without_tokens $with_tokens ok"
}

run_benchmark_code_write() {
  local idx="$1"
  local spec reference context_corpus

  spec=$(jq -r ".benchmarks[$idx].spec" "$BENCHMARKS")
  reference="$SCRIPT_DIR/$(jq -r ".benchmarks[$idx].reference" "$BENCHMARKS")"

  context_corpus=""
  while IFS= read -r p; do
    context_corpus="$context_corpus$(cat "$SCRIPT_DIR/$p")"
  done < <(jq -r ".benchmarks[$idx].context_files[]" "$BENCHMARKS")

  # Run code-write with --target so output goes to disk
  local target_file="${TMPDIR:-/tmp}/kirunt-codegen-output.ts"
  if ! "$KIRUNT_DIR/scripts/code-write" --spec "$spec" --reference "$reference" --target "$target_file" 2>/dev/null; then
    rm -f "$target_file"
    echo "0 0 0 fail"
    return
  fi

  local generated=""
  [ -f "$target_file" ] && generated=$(cat "$target_file")

  # Without kirunt: the main agent reads context files + generates code as
  # output tokens. Output tokens cost more than input tokens, so weight them
  # accordingly (5x, matching the original's conservative estimate).
  local input_tokens output_tokens without_tokens
  input_tokens=$(token_estimate "$context_corpus")
  output_tokens=$(token_estimate "$generated")
  without_tokens=$(( input_tokens + output_tokens * 5 ))

  # With kirunt: the main agent sends a short spec, code goes to disk, the
  # main agent's context sees nothing of the generated content.
  local with_tokens=0

  rm -f "$target_file"
  echo "0 $without_tokens $with_tokens ok"
}

run_benchmark_mcp_call() {
  local idx="$1"
  local question mcp_config_rel mcp_config mcp_caller_mode

  question=$(jq -r ".benchmarks[$idx].question" "$BENCHMARKS")
  mcp_config_rel=$(jq -r ".benchmarks[$idx].mcp_config" "$BENCHMARKS")
  mcp_config="$SCRIPT_DIR/$mcp_config_rel"
  mcp_caller_mode=$(jq -r ".benchmarks[$idx].mcp_caller_mode // \"worker\"" "$BENCHMARKS")

  # includeMcpJson resolves servers from the CWD's .kiro/settings/mcp.json
  # (plus the user-level one), not an arbitrary file — so point the worker
  # at the fixture by running mcp-call from a scratch dir whose project MCP
  # config is the fixture. This keeps the fixture server from being visible
  # to any other suite or to a real project's own MCP config.
  local workdir
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.kiro/settings" "$workdir/evals/fixtures"
  cp "$mcp_config" "$workdir/.kiro/settings/mcp.json"
  # The fixture config's command path (evals/fixtures/mcp-fixture-server.js)
  # is relative to cwd, so link it in under the same relative path.
  ln -sf "$SCRIPT_DIR/fixtures/mcp-fixture-server.js" "$workdir/evals/fixtures/mcp-fixture-server.js"

  local response
  local mode_config="$workdir/.kirunt-config.json"
  jq -n --arg mode "$mcp_caller_mode" \
    '{worker_model: "claude-haiku-4.5", min_lines: 350, timeout_seconds: 180, enable_bulk_reader: true, enable_code_writer: true, enable_mcp_caller: true, mcp_caller_mode: $mode}' \
    > "$mode_config"
  if ! response=$(cd "$workdir" && KIRUNT_CONFIG_PATH="$mode_config" "$KIRUNT_DIR/scripts/mcp-call" --question "$question" 2>/dev/null); then
    rm -rf "$workdir"
    echo "0 0 0 fail"
    return
  fi
  [ -z "$response" ] && { rm -rf "$workdir"; echo "0 0 0 fail"; return; }

  rm -rf "$workdir"

  # Without kirunt: the fixture page's raw content would land in the main
  # agent's context. With kirunt: only the worker's distilled answer does.
  local page_corpus without_tokens with_tokens
  page_corpus=$(sed -n '/^const PAGE_CONTENT/,/^};/p' "$SCRIPT_DIR/fixtures/mcp-fixture-server.js")

  without_tokens=$(token_estimate "$page_corpus")
  with_tokens=$(token_estimate "$response")

  echo "0 $without_tokens $with_tokens ok"
}

BENCH_FAILED=false

run_benchmarks() {
  # shellcheck source=../scripts/lib/kirunt.sh
  . "$KIRUNT_DIR/scripts/lib/kirunt.sh"
  if ! kirunt_preflight; then
    printf "\n\033[33mSkipping benchmarks: kiro-cli or jq not available\033[0m\n"
    return
  fi

  local count
  count=$(jq '.benchmarks | length' "$BENCHMARKS")

  echo ""
  echo "Token savings benchmark (worker model: $KIRUNT_WORKER_MODEL)"
  echo "────────────────────────────────────────────────────────────────────────────────"

  local total_without=0 total_with=0
  declare -a rows

  for ((i = 0; i < count; i++)); do
    local name btype
    name=$(jq -r ".benchmarks[$i].name" "$BENCHMARKS")
    btype=$(jq -r ".benchmarks[$i].type" "$BENCHMARKS")

    printf "  \033[2mRunning [%s] %s...\033[0m\n" "$btype" "$name"

    local total_lines without_tokens with_tokens status
    if [ "$btype" = "bulk-read" ]; then
      read -r total_lines without_tokens with_tokens status <<< "$(run_benchmark_bulk_read "$i")"
    elif [ "$btype" = "code-write" ]; then
      read -r total_lines without_tokens with_tokens status <<< "$(run_benchmark_code_write "$i")"
    elif [ "$btype" = "mcp-call" ]; then
      read -r total_lines without_tokens with_tokens status <<< "$(run_benchmark_mcp_call "$i")"
    else
      continue
    fi

    if [ "$status" != "ok" ]; then
      printf "  \033[31mFAIL\033[0m  %-25s delegation failed — not reporting fake savings\n" "$name"
      BENCH_FAILED=true
      continue
    fi

    local pct=0
    if [ "$without_tokens" -gt 0 ]; then
      pct=$(( (without_tokens - with_tokens) * 100 / without_tokens ))
    fi

    total_without=$(( total_without + without_tokens ))
    total_with=$(( total_with + with_tokens ))

    local file_info
    if [ "$total_lines" -gt 0 ]; then
      file_info="${total_lines} lines"
    else
      file_info="codegen"
    fi

    rows+=("$name|$file_info|$without_tokens|$with_tokens|$pct")
  done

  echo ""
  printf "  %-25s  %10s  %14s  %14s  %8s\n" "Scenario" "Input" "Without kirunt" "With kirunt" "Savings"
  printf "  %-25s  %10s  %14s  %14s  %8s\n" "─────────────────────────" "──────────" "──────────────" "──────────────" "────────"

  for r in "${rows[@]}"; do
    IFS='|' read -r name file_info without_tokens with_tokens pct <<< "$r"
    local color='\033[32m'
    [ "$pct" -lt 80 ] && color='\033[36m'
    [ "$pct" -lt 50 ] && color='\033[31m'
    printf "  %-25s  %10s  %11s tk  %11s tk  ${color}%5s%%\033[0m\n" \
      "$name" "$file_info" "$without_tokens" "$with_tokens" "$pct"
  done

  printf "  %-25s  %10s  %14s  %14s  %8s\n" "─────────────────────────" "──────────" "──────────────" "──────────────" "────────"

  local total_pct=0
  if [ "$total_without" -gt 0 ]; then
    total_pct=$(( (total_without - total_with) * 100 / total_without ))
  fi

  printf "  \033[1m%-25s  %10s  %11s tk  %11s tk  \033[32m%5s%%\033[0m\n" \
    "Total" "" "$total_without" "$total_with" "$total_pct"
  echo ""
  printf "  \033[2mToken estimate: chars / 4. Output tokens weighted 5x.\033[0m\n"
  printf "  \033[2mBulk-read: without = file content in context, with = worker-agent summary in context.\033[0m\n"
  printf "  \033[2mCode-write: without = read files + generate code, with = code written to disk.\033[0m\n"
  printf "  \033[2mMCP-call: without = raw MCP tool response in context, with = worker-agent distilled answer in context.\033[0m\n"
}

# ── Main ──

run_suite "$KIRUNT_DIR/hooks/check-file-size" "$SCRIPT_DIR/hook-evals.json" "Read hook (check-file-size)"
run_suite "$KIRUNT_DIR/hooks/check-bash-read" "$SCRIPT_DIR/bash-hook-evals.json" "Bash hook (check-bash-read)"
run_transport_suite
run_mcp_call_suite

if [ "$RUN_MCP_LIVE" = true ]; then
  run_mcp_live_suite
fi

echo ""
echo "════════════════════════════════════════════════════════════════"
printf "Total: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m, %d total\n" "$PASSED" "$FAILED" "$TOTAL"

if [ "$RUN_BENCHMARK" = true ]; then
  run_benchmarks
fi

if [ "$RUN_CONTEXT_BENCHMARK" = true ]; then
  bash "$SCRIPT_DIR/context-benchmark.sh"
fi

echo ""
[ "$FAILED" -gt 0 ] && exit 1
[ "$BENCH_FAILED" = true ] && exit 1
exit 0
