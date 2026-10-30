# AGENTS.md

kirunt is a bash-only Kiro CLI agent bundle. Three layers: `hooks/` block large reads, `scripts/` delegate to worker agents via `kiro-cli chat`, and `skills/` tell the main model when to call those scripts. There is no build step; runtime deps are `bash`, `jq`, and `kiro-cli`.

## Engine target

- **Kiro CLI V3** is the tested target (validated on 2.36.0). V3 uses `read_file`/`execute_bash` tool IDs, loads MCP tools on demand, and no longer has the `tool_search` tool.
- `kiro-cli settings list` is the source of truth for the active engine (`chat.agentEngine`). V3 may be active even without `--v3`.
- Hook scripts still accept the CLI V2 payload for compatibility, but new work targets V3.

## Path convention

- **The bundle root is this repo root.** Use `scripts/...`, `hooks/...`, `evals/...`, and `install/install.sh` from the root.
- `agents/kirunt.json` is the main agent's source of truth (prompt/tools/hooks). Its hook and skill paths are bundle-root-relative so a workspace-local `.kiro/agents/` copy works when launched from the root. `install/install.sh` rewrites them for global installs — edit the source config, not the installed `~/.kiro/agents/kirunt.json`.

## Key files

- `config.json` — the only tunables (`worker_model`, `min_lines`, `timeout_seconds`, feature flags, `mcp_caller_mode`). Loaded at runtime through `scripts/lib/kirunt.sh`; there are no env-var overrides. `KIRUNT_KIRO_CLI_BIN` is the exception; `KIRUNT_CONFIG_PATH` is an internal test seam, not user config.
- `scripts/lib/kirunt.sh` — config loading, defaults, and `kirunt_invoke`. Hooks and scripts source it; change shared behavior here once, not per script. An empty agent name makes `kirunt_invoke` omit `--agent` (required for built-in agents in V3).
- `hooks/check-file-size` — handles both V3 `read_file` (`tool_input.path` + `offset`/`limit`, resolved against `cwd`) and V2 `tool_input.operations[]`.
- `hooks/check-bash-read` — handles `execute_bash` (V3) and the V2 shell payload; both put the command in `tool_input.command`.
- Hook contract: JSON event on stdin; exit `0` allows, exit `2` blocks with the reason on stderr. Do not switch to Claude Code's stdout-JSON decision convention.
- `agents/kirunt-*.json` — worker agents. `kirunt-bulk-reader` and `kirunt-code-writer` are deliberately tool-less (`"tools": []`); `kirunt-mcp-caller` gets `@mcp` plus `includeMcpJson`. Don't grant workers extra tools.
- `skills/*/SKILL.md` — model-facing usage guidance. Keep script paths here in sync with the repo layout.
- `evals/fixtures/` — checked-in benchmark fixtures. `evals/.fixtures/` is generated and deleted by `run.sh`; don't edit it.

## Commands

```bash
bash evals/run.sh                      # 79 offline cases: hooks (V2+V3), transport, mcp-call
bash evals/config-evals.sh             # config.json loading/fallback suite (NOT wired into run.sh)
bash evals/run.sh --benchmark          # live worker model; token-savings estimate
bash evals/run.sh --context-benchmark  # live; V2-only today (V3 logs lack the usage field)
bash evals/run.sh --mcp-live           # live MCP worker behavior; needs node + model access
install/install.sh                     # global install to ~/.kiro/kirunt; idempotent
install/install.sh --mcp-caller-mode kiro-default  # install with built-in default agent
install/install.sh --uninstall
```

- Run `bash evals/run.sh` after any hook, script, or config change. All 79 offline cases must pass; it needs `jq` but no model access.
- `bash evals/run.sh --mcp-live` adds 9 live MCP-worker checks using `evals/fixtures/mcp-fixture-server.js`; it needs `node`, `kiro-cli`, and model access. Run it after changing the MCP worker prompt/config.
- Hook eval fixtures still name overrides with `KIRUNT_*` env names, but `run.sh` translates them into a temporary `config.json` and points hooks at it via `KIRUNT_CONFIG_PATH`. Don't reintroduce env reads for tunables.
- `evals/run.sh --benchmark` now fails loudly when a delegation returns no answer; do not restore the old `|| true` swallow that reported false 100% savings.

## Invariants and gotchas

- `enable_bulk_reader` is the single switch read by both hooks and `bulk-read`. Never disable bulk-reader by editing only one side — set the flag (or raise `min_lines` instead). Hooks still blocking while delegation is off strands the agent.
- `install/install.sh` copies `config.json` and derives `~/.kiro/agents/kirunt.json`, including the V3 profile-scoped `hooks` array. Installed copies are independent, not symlinks. Re-run the installer to propagate repo edits.
- `install/install.sh` is also the curl bootstrap. When piped there is no `BASH_SOURCE` file, so it downloads `https://github.com/$KIRUNT_REPO/archive/<branch-or-tag>.tar.gz`, extracts it, and re-runs the bundled installer. `KIRUNT_REPO` defaults to `Redooz/kirunt` (override it for forks); `KIRUNT_VERSION` defaults to `main`. Local checkout mode must keep working without either variable. Test remote mode offline with `KIRUNT_ARCHIVE_URL=file:///tmp/kirunt.tar.gz`.
- Every `kirunt_invoke` call is a fresh one-shot `kiro-cli chat --no-interactive` session with no memory of prior calls. Follow-ups must resend their inputs.
- Defaults are duplicated in three places: `config.json`, the hardcoded fallbacks in `kirunt.sh`, and eval expectations (`config-evals.sh` asserts the exact live config values; the hook eval JSONs encode the threshold). Update them together.
- `worker_model` ships as `claude-haiku-4.5`; `claude-haiku-5.5` is recommended in the READMEs *where the catalog exposes it*, but don't bump the shipped default without verifying it live on the target engine.
- `mcp_caller_mode` ships as `worker` (verified on V3 2.36.0). For Kiro CLI 2.x / the V2 engine, use `kiro-default` (the built-in default agent) via `--mcp-caller-mode kiro-default`. `kiro-default` must omit `--agent`; passing `--agent kiro_default` errors on V3.
- `install/install.sh --mcp-caller-mode worker|kiro-default` (or `KIRUNT_MCP_CALLER_MODE`) chooses the mode at install time and rejects invalid values. Remote installs pass the same flag after `bash -s --`.
- Keep hooks profile-scoped. Installing them as global `~/.kiro/hooks/*.json` would block large reads for every agent on the machine.
