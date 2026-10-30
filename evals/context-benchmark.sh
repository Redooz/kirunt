#!/bin/bash
# Real context-window benchmark: measures actual per-request context usage
# reported by kiro-cli's own backend, instead of the chars/4 heuristic used
# by the token-savings benchmark in run.sh.
#
# WHY THIS EXISTS
# kiro-cli has no public API or slash command that returns an absolute
# token count. `/usage` reports account-level billing credits, not
# per-request tokens. `/context` reports a context-window percentage
# rounded to one decimal. Neither is precise enough to score a single
# fixture file in isolation.
#
# At KIRO_LOG_LEVEL=trace, the CLI's own V2 log
# ($TMPDIR/kiro-log/kiro-chat.log on macOS) records an EndStream event per
# turn containing `context_usage_percentage` as an unrounded float (e.g.
# 3.0220000743865967), plus `user_prompt_length` / `response_size` (char
# counts). CLI V3 moved logs to ~/.kiro/logs/<timestamp>/kiro.log; this
# script looks for either location, but V3's current format does not expose
# context_usage_percentage, so scenarios report n/a rather than fake data. The same struct has total_tokens/output_tokens/*_input_tokens
# fields, but the backend never fills them in — they are always None. The
# percentage is the most precise real signal available.
#
# METHOD
# kiro-cli always folds in global resources (skills, steering, AGENTS.md,
# etc. under ~/.kiro) on top of whatever an agent's `resources` declares,
# so a single measurement is polluted by whatever happens to be installed
# on the machine running the benchmark. To cancel that noise, each
# scenario is measured twice against a throwaway agent in a throwaway
# workspace:
#   1. baseline: agent with resources: [] -> percentage0 (pure environment
#      noise: global skills/steering/AGENTS.md, tool schemas, the
#      question text itself)
#   2. loaded:   same agent with resources: ["file://<fixture>", ...] ->
#      percentage1
# delta = percentage1 - percentage0 is attributed to the fixture files.
# delta% * max_input_tokens (from the model's own advertised context
# window, also visible in the trace log) approximates the fixture's real
# token cost.
#
# CAVEATS (see also README section this feeds into)
# - Reads an undocumented internal log format; a kiro-cli update can
#   silently break the parsing here.
# - KIRO_LOG_LEVEL=trace logs can contain file paths/code/command output;
#   this script deletes the scratch log directory when done.
# - percentage-of-window is still an approximation of true token count,
#   not an exact figure — but it is a materially closer approximation
#   than chars/4, since it comes from the backend's own accounting.
# - Needs live kiro-cli + model access, like --benchmark. Not run by
#   default.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KIRUNT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BENCHMARKS="$SCRIPT_DIR/benchmarks.json"

# shellcheck source=../scripts/lib/kirunt.sh
. "$KIRUNT_DIR/scripts/lib/kirunt.sh"

WORKDIR=""
LOG_DIR=""
LOG_DIR_PARENT=""

cleanup() {
  [ -n "$WORKDIR" ] && rm -rf "$WORKDIR"
  # KIRO_LOG_LEVEL=trace logs can contain file paths/code/command output —
  # scrub the whole scratch TMPDIR (parent of kiro-log/) rather than
  # leaving any of it behind, empty or not.
  [ -n "$LOG_DIR_PARENT" ] && rm -rf "$LOG_DIR_PARENT"
}
trap cleanup EXIT

context_benchmark_preflight() {
  kirunt_preflight || return 1
  command -v python3 >/dev/null 2>&1 || {
    echo "Error: python3 is required to parse trace logs (json/regex parsing)" >&2
    return 1
  }
  return 0
}

# Creates an isolated workspace with a throwaway agent config.
#   $1 workspace dir to create
#   $2 JSON array string of resource entries, e.g. '["file://a.ts","file://b.ts"]'
make_agent_workspace() {
  local dir="$1" resources_json="$2"
  mkdir -p "$dir/.kiro/agents"
  cat > "$dir/.kiro/agents/kirunt-ctx-bench.json" <<EOF
{
  "name": "kirunt-ctx-bench",
  "description": "Throwaway agent for kirunt's context-window benchmark. Not for interactive use.",
  "tools": [],
  "resources": $resources_json
}
EOF
}

# Runs one no-interactive turn against the scratch agent with trace logging,
# then extracts the EndStream context_usage_percentage for that turn.
#   $1 workspace dir (must contain .kiro/agents/kirunt-ctx-bench.json)
#   $2 message to send
#   $3 model id
# Prints the percentage (float) to stdout, or "null" if not found.
run_and_extract_percentage() {
  local workdir="$1" message="$2" model="$3"
  local log_file="$LOG_DIR/kiro-chat.log" marker v3_log

  rm -f "$log_file"
  marker="$LOG_DIR_PARENT/.start-marker"
  touch "$marker"

  (
    cd "$workdir" && \
    KIRO_LOG_LEVEL=trace TMPDIR="$LOG_DIR_PARENT" "$KIRUNT_KIRO_CLI_BIN" chat \
      --no-interactive \
      --agent kirunt-ctx-bench \
      --model "$model" \
      --trust-all-tools \
      "$message" >/dev/null 2>&1
  ) || true

  # CLI V2 wrote a dedicated kiro-chat.log. CLI V3 writes timestamped
  # ~/.kiro/logs/<timestamp>/kiro.log directories instead.
  if [ ! -f "$log_file" ]; then
    v3_log=$(find "$HOME/.kiro/logs" -type f -name 'kiro.log' -newer "$marker" 2>/dev/null | sort | tail -1)
    [ -n "$v3_log" ] && log_file="$v3_log"
  fi
  rm -f "$marker"

  if [ ! -f "$log_file" ]; then
    echo "null"
    return
  fi

  # Take the last EndStream's context_usage_percentage in this fresh log —
  # each call gets a truncated/fresh log dir so there is at most one turn.
  python3 - "$log_file" <<'PYEOF'
import re, sys

path = sys.argv[1]
try:
    text = open(path, encoding="utf-8", errors="ignore").read()
except FileNotFoundError:
    print("null")
    sys.exit(0)

patterns = [
    r"context_usage_percentage:\s*Some\(([0-9.]+)\)",
    r'"context_usage_percentage"\s*:\s*([0-9.]+)',
    r'"contextUsagePercentage"\s*:\s*([0-9.]+)',
]
for pattern in patterns:
    matches = re.findall(pattern, text)
    if matches:
        print(matches[-1])
        sys.exit(0)
print("null")
PYEOF
}

# Runs baseline (empty resources) + loaded (fixture resources) for one
# scenario and prints: delta_percentage max_input_tokens
run_scenario_delta() {
  local idx="$1" model="$2"
  local question paths_json message

  question=$(jq -r ".benchmarks[$idx].question // .benchmarks[$idx].spec" "$BENCHMARKS")

  # Build resources JSON array and copy fixtures into the workspace so
  # file:// paths resolve relative to the throwaway agent's cwd.
  local resources=() 
  while IFS= read -r p; do
    local base
    base=$(basename "$p")
    cp "$SCRIPT_DIR/$p" "$WORKDIR/$base"
    resources+=("\"file://$base\"")
  done < <(jq -r ".benchmarks[$idx].paths[]? // .benchmarks[$idx].context_files[]?" "$BENCHMARKS")

  local resources_json="[]"
  if [ "${#resources[@]}" -gt 0 ]; then
    resources_json="[$(IFS=,; echo "${resources[*]}")]"
  fi

  message="$question"

  # Baseline: same workspace/question, but resources: [] — cancels out
  # global skills/steering/AGENTS.md noise and the question's own tokens.
  make_agent_workspace "$WORKDIR" "[]"
  local pct0
  pct0=$(run_and_extract_percentage "$WORKDIR" "$message" "$model")

  # Loaded: fixture files declared as resources.
  make_agent_workspace "$WORKDIR" "$resources_json"
  local pct1
  pct1=$(run_and_extract_percentage "$WORKDIR" "$message" "$model")

  if [ "$pct0" = "null" ] || [ "$pct1" = "null" ]; then
    echo "null"
    return
  fi

  python3 -c "print(f'{float(\"$pct1\") - float(\"$pct0\"):.6f}')"
}

main() {
  if ! context_benchmark_preflight; then
    printf "\n\033[33mSkipping context benchmark: kiro-cli, jq, or python3 not available\033[0m\n"
    return 0
  fi

  local model="${KIRO_CONTEXT_BENCHMARK_MODEL:-claude-sonnet-4.5}"
  local max_input_tokens="${KIRO_CONTEXT_BENCHMARK_WINDOW:-200000}"

  WORKDIR=$(mktemp -d)
  LOG_DIR_PARENT=$(mktemp -d)
  LOG_DIR="$LOG_DIR_PARENT/kiro-log"
  mkdir -p "$LOG_DIR"

  local count measured=0
  count=$(jq '.benchmarks | length' "$BENCHMARKS")

  echo ""
  echo "Real context-window benchmark (model: $model, window: $max_input_tokens tk)"
  echo "────────────────────────────────────────────────────────────────────────────────"
  printf "  %-25s  %12s  %12s\n" "Scenario" "Δ context%" "~tokens"
  printf "  %-25s  %12s  %12s\n" "─────────────────────────" "────────────" "────────────"

  for ((i = 0; i < count; i++)); do
    local name
    name=$(jq -r ".benchmarks[$i].name" "$BENCHMARKS")

    printf "  \033[2mMeasuring %s...\033[0m\n" "$name" >&2

    local delta
    delta=$(run_scenario_delta "$i" "$model")

    if [ "$delta" = "null" ]; then
      printf "  %-25s  %12s  %12s\n" "$name" "n/a" "n/a"
      continue
    fi
    measured=$((measured + 1))

    local tokens
    tokens=$(python3 -c "print(round(max(float(\"$delta\"), 0) / 100 * $max_input_tokens))")

    printf "  %-25s  %11s%%  %10s tk\n" "$name" "$delta" "$tokens"
  done

  echo ""
  if [ "$measured" -eq 0 ]; then
    printf "  \033[33mNo context_usage_percentage was found in the trace log.\033[0m\n"
    printf "  \033[33mCLI V3 logs live under ~/.kiro/logs/<timestamp>/kiro.log and do not currently expose that field.\033[0m\n"
    printf "  \033[33mThis cross-check is V2-only until a usable V3 usage signal is identified.\033[0m\n"
  fi
  printf "  \033[2mΔ context%% = (resources loaded) - (empty baseline), same question, same workspace.\033[0m\n"
  printf "  \033[2m~tokens = Δ context%% / 100 * model's advertised max_input_tokens (approximation).\033[0m\n"
  printf "  \033[2mSource: kiro-chat.log (V2) or ~/.kiro/logs/*/kiro.log (V3) at KIRO_LOG_LEVEL=trace.\033[0m\n"
  printf "  \033[2mThis is a cross-check against the chars/4 estimate in --benchmark, not a replacement.\033[0m\n"
}

main "$@"
