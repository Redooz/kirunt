# kirunt

[English](README.md) · [Español](README_ES.md)

kirunt is an **agent bundle** that delegates I/O-heavy work — large file reads, boilerplate
generation, and MCP tool calls — to a cheaper worker model, saving tokens on all three.

kirunt is a bundle, not a harness: Kiro CLI owns the model loop, tool execution, and context
window, while kirunt supplies the agent configuration, worker agents, hooks, scripts, and skills
that run on top of it. kirunt delegates through `kiro-cli chat --no-interactive` itself — no
external CLI, service, or authentication beyond what you already use to run `kiro-cli`.

Kiro is usable from both the IDE and the CLI. kirunt installs its agent profiles under
`~/.kiro/agents/`, so both surfaces can load them.

kirunt also keeps the main agent's context lighter: `agents/kirunt.json` exposes only the
`read`, `write`, `shell`, and `web` tool groups and no MCP tools. The default agent loads more
built-ins and configured MCP servers. Large file reads and MCP responses are handled by worker
sessions instead, so they never enter the main agent's context.

## How it works

Three layers, from hard gate to soft suggestion:

1. **Hooks** block the `kirunt` agent from reading large files and redirect to the bulk-reader skill.
2. **Scripts** invoke a dedicated worker agent via `kiro-cli chat` and clean up its output.
3. **Skills** tell the model when and how to call the scripts.

The agent doesn't need to figure out how to delegate. It calls a script with named arguments,
and the script handles the rest — including starting the worker agent.

## Prerequisites

- [`jq`](https://jqlang.org/download/)
- [`kiro-cli`](https://kiro.dev/cli/)
- A worker model you're allowed to call with `--model` (defaults to `claude-haiku-4.5` — see
  [Configuration](#configuration) to change it)
- Kiro CLI V3 is the tested target (validated on 2.36.0). Hooks also handle the V2 payload for
  compatibility, but current builds run V3.

> [!IMPORTANT]
> Model names are tied to your account and to the current model catalog, so they age. **Prefer
> `claude-haiku-5.5` when your account exposes it** — it's the newest cheap worker and the
> recommended choice where available; `claude-haiku-4.5` is the shipped default because it's the
> broader-availability fallback. Set `worker_model` in `config.json` to switch. Nothing else needs
> to change — scripts and worker agent configs never hardcode a model name.

## Install

kirunt is an agent bundle distributed as plain files: installing it means placing its pieces where
`kiro-cli` discovers them — the agent configs in `~/.kiro/agents/` and the runtime bundle
(hooks, scripts, skills) in a stable location.

> [!NOTE]
> **Installing on Kiro CLI 2.x / the V2 engine?** use Kiro's built-in default agent for MCP
> calls. Install with `--mcp-caller-mode kiro-default`, or set
> `"mcp_caller_mode": "kiro-default"` in `config.json`. The worker-agent path is V3-oriented.
> kirunt's hooks and scripts still accept the V2 payload, so read blocking, `bulk-read`, and
> `code-write` work on the V2 engine in Kiro 2.36.0.

### Install from GitHub

Requires `curl` and `tar`. The installer downloads `Redooz/kirunt` by default — set
`KIRUNT_REPO=OWNER/REPO` to install from a fork:

```bash
curl -fsSL https://raw.githubusercontent.com/Redooz/kirunt/main/install/install.sh | bash
```

Then use it anywhere:

```bash
kiro-cli chat --agent kirunt
```

Optionally make it the default agent (no `--agent` flag needed):

```bash
kiro-cli agent set-default kirunt
```

### Installer options

```bash
# Pin a branch or release tag
curl -fsSL https://raw.githubusercontent.com/Redooz/kirunt/main/install/install.sh \
  | KIRUNT_VERSION=v0.1.0 bash

# Install elsewhere
curl -fsSL https://raw.githubusercontent.com/Redooz/kirunt/main/install/install.sh \
  | KIRUNT_HOME=/opt/kirunt bash

# Install from a fork
curl -fsSL https://raw.githubusercontent.com/Redooz/kirunt/main/install/install.sh \
  | KIRUNT_REPO=OWNER/kirunt bash

# Use Kiro's built-in default agent for MCP calls (V2 / fallback)
curl -fsSL https://raw.githubusercontent.com/Redooz/kirunt/main/install/install.sh \
  | bash -s -- --mcp-caller-mode kiro-default

# Uninstall
curl -fsSL https://raw.githubusercontent.com/Redooz/kirunt/main/install/install.sh \
  | bash -s -- --uninstall
```

Set `KIRUNT_SHA256` to verify the downloaded archive. The installer rejects any
`mcp_caller_mode` other than `worker` or `kiro-default`.

### Development install from a checkout

For work on kirunt itself, run the installer directly. This is the same script the one-liner
uses:

```bash
install/install.sh
```

The same options apply: `KIRUNT_HOME=/opt/kirunt install/install.sh`,
`install/install.sh --mcp-caller-mode kiro-default`, and `install/install.sh --uninstall`.
Re-running is idempotent.

Validate any installed config:

```bash
kiro-cli agent validate --path ~/.kiro/agents/kirunt.json
```

## Scripts

### bulk-read

Delegates file reading to the `kirunt-bulk-reader` worker agent. Files are wrapped in XML tags
(`<file path="...">`) for clear boundaries.

```bash
scripts/bulk-read --question "What does this service do?" --paths src/Service.ts src/Handler.ts

# Follow-up: ask again with the same paths
scripts/bulk-read --question "Which methods call the database?" --paths src/Service.ts src/Handler.ts
```

### code-write

Delegates boilerplate generation to the `kirunt-code-writer` worker agent. Strips markdown fences
from output. Can write directly to disk via `--target`. `--reference` is required — without a
file to match patterns against, the worker would generate context-free code that fits nothing in
the project.

```bash
# Generate and write to file
scripts/code-write --spec "Write tests for UserService" --reference tests/OrderTest.ts --target tests/UserTest.ts

# Build on what was just generated by referencing it
scripts/code-write --spec "Now add edge case tests" --reference tests/UserTest.ts --target tests/UserEdgeCases.ts

# Output to stdout
scripts/code-write --spec "Generate a config stub" --reference config/existing.yaml
```

### mcp-call

Delegates a call to an MCP server (Confluence, AWS docs, GitHub, and so on) to a worker model. The main kirunt agent has no MCP tools of its own, so the server's raw response would otherwise land in its context. The worker reads the response and returns only the distilled answer.

```bash
# Ask a question; the worker finds the right tool
scripts/mcp-call --question "Search Confluence for the Q3 rollout page and summarize the timeline"

# Call a known tool directly (skips the discovery step)
scripts/mcp-call --tool "@confluence/conf_search" --args '{"query":"Q3 rollout"}' --question "Summarize the top result"
```

`--args` and `--args-file` take JSON arguments for `--tool`. Pass one or the other, not both. `--args` needs `--tool`.

The mode is set by `mcp_caller_mode` in `config.json`:
- `worker` (shipped default): delegates to the dedicated `kirunt-mcp-caller` agent, which uses
  `includeMcpJson` + `@mcp` and works on Kiro CLI V3 (verified on 2.36.0, where MCP tools load
  on demand).
- `kiro-default`: delegates to Kiro's built-in default agent. Use this mode on Kiro CLI 2.x /
  the V2 engine, or when you want the default agent to handle MCP calls. On CLI V3, built-ins
  are selected by omitting `--agent`; passing `--agent kiro_default` now errors.

### One shot per call

Each `kiro-cli chat --no-interactive` invocation is a fresh session with no memory of prior
calls. Replaying a file corpus across calls is the exact cost this bundle exists to avoid, so
kirunt does not do it — every call stands alone. Re-sending files is free where it matters,
because the corpus goes to the worker model and never enters the main agent's context.

## Hooks

### check-file-size (`read` hook)

Fires on every `read` tool call. Blocks full-file reads on files exceeding `min_lines`
(config.json; default: 350). Handles both the CLI V3 single `read_file` payload
(`tool_input.path` + `offset`/`limit`, resolved against the event's `cwd`) and the CLI V2
batched `tool_input.operations[]` payload. Allows through:
- Targeted reads (`offset` or `limit` set — including `0`)
- Files under the threshold
- Nonexistent files (let `read` handle the error)
- Non-`read_file` tools covered by the `read` matcher (directory listing, search, etc.)
- Everything, unconditionally, when `enable_bulk_reader: false` in config.json (see below)

### check-bash-read (`shell` hook)

Fires on every `shell` tool call. Catches `cat`, `head`, `tail`, `less`, `more` on large files.
Allows through:
- Piped commands (`cat file | grep`) — targeted reads
- Redirections (`cat file > out`) — not reading into context
- Non-read commands (`git status`, `grep`, etc.)
- Everything, unconditionally, when `enable_bulk_reader: false` in config.json

Both hooks read the `PreToolUse` event JSON from stdin and signal their decision via exit code:
`0` allows, `2` blocks with the reason on stderr (Kiro's hook contract — different from Claude
Code's JSON-decision-on-stdout convention the original plugin used). The hooks are installed as
profile-scoped V3 hook definitions (`trigger: "PreToolUse"`), not global `~/.kiro/hooks/` files,
so they only gate the `kirunt` agent.

## Configuration

All of kirunt's tunables live in one file: `config.json`
(or `~/.kiro/kirunt/config.json` once installed). There are no environment
variables for these settings — edit the JSON directly.

| Key | Type | Default | Purpose |
|-----|------|---------|---------|
| `min_lines` | number | `350` | Line count above which the read/bash hooks block and redirect |
| `worker_model` | string | `claude-haiku-4.5` | Model passed to `kiro-cli chat --model` for delegated calls. **The one place to edit to swap the worker model** — scripts and worker agent configs never hardcode a model name. Prefer `claude-haiku-5.5` when your account exposes it |
| `timeout_seconds` | number | `180` | Ceiling for one worker invocation |
| `enable_bulk_reader` | boolean | `true` | Single authoritative switch for the bulk-reader capability — see below |
| `enable_code_writer` | boolean | `true` | Switch for the code-writer capability — script-only, no hook to coordinate |
| `enable_mcp_caller` | boolean | `true` | Switch for the mcp-caller capability — script-only, no hook to coordinate |
| `mcp_caller_mode` | string | `worker` | `worker` (dedicated `kirunt-mcp-caller` agent, V3 default) or `kiro-default` (Kiro's built-in default agent — selected by omitting `--agent` under V3; see comments in `scripts/lib/kirunt.sh`). An unrecognized value falls back to `worker` |

`KIRUNT_KIRO_CLI_BIN` remains an environment variable, not a `config.json`
setting: it overrides how the `kiro-cli` binary itself is launched for
delegated calls — that's low-level plumbing for pointing at a different
binary, not a kirunt behavior setting.

No restart is needed after editing `config.json` — every hook/script
invocation re-reads it from disk.

If you installed kirunt globally (`install/install.sh`), edit
`~/.kiro/kirunt/config.json` instead — it's an independent copy of the
repo file, not a symlink. Re-run `install.sh` to propagate a repo-side
change to an existing install.

### Disabling bulk-reader safely

`enable_bulk_reader` is read by **both** hooks and the `bulk-read` script, and it is the
single switch that keeps them in sync. Setting it to `false`:
- Makes `check-file-size` and `check-bash-read` allow everything through unconditionally
  (they stop blocking, since there would be nowhere useful to redirect to).
- Makes `bulk-read` itself refuse to run (defense in depth, in case something calls it directly).

Do **not** try to disable bulk-reader by only editing the script or only editing the hooks —
if the hooks still block but delegation is disabled, the main agent gets stuck: blocked from
reading directly, refused by the delegation path, and pushed into inefficient chunked
`offset`/`limit` reads that cost roughly as many tokens as one big read (sometimes more, from
repeated tool-call overhead). If you want to throttle rather than fully disable, raise
`min_lines` instead — that keeps the block/delegate pair coherent while changing where the
line falls.

### Disabling code-writer

`enable_code_writer: false` is safe and clean — there is no hook enforcing code-writer use
(same limitation the original plugin documented), so disabling it just means the main agent
falls back to writing the code itself, exactly as if this bundle were not installed.

## What doesn't get delegated

This bundle is designed to know when NOT to delegate:
- **Debugging** — requires the main agent's reasoning, not a summary
- **Editing** — the agent needs exact content in context; use targeted reads (`offset`/`limit`)
- **Small files** — delegation overhead exceeds savings under the threshold
- **Architectural decisions** — judgment calls stay with the main agent

## Evals

```bash
# Hook routing + transport plumbing — no live model access needed (stubs kiro-cli)
bash evals/run.sh

# Also re-measure token savings against the real worker model — needs kiro-cli + model access
bash evals/run.sh --benchmark

# Cross-check the estimate above against kiro-cli's own real context-window accounting
# (V2-only today; see "Benchmarks" below) — needs kiro-cli + model access
bash evals/run.sh --context-benchmark

# Live MCP worker behavior — needs kiro-cli + model access and node (fixture MCP server)
bash evals/run.sh --mcp-live
```

`run.sh` runs 79 offline cases: 28 for `check-file-size` (V2 and V3 payloads), 20 for
`check-bash-read`, 15 for the transport layer (`scripts/lib/kirunt.sh`, stubbed `kiro-cli`), and
16 for `mcp-call` (argument validation and delegation mode, also with a stubbed `kiro-cli`). All
must pass (exit 0) with no live model access. `--mcp-live` adds 9 live checks against the fixture
MCP server: a lookup with a generic tools hint must call the MCP tool, a self-contained
arithmetic question must not, and an explicit `--tool` call must reach the fixture server.
`evals.json` holds 6 end-to-end scenarios describing expected model behavior (bulk-read redirect,
code-write generation, a debugging case that should NOT delegate, MCP delegation discovery, an
empty-MCP failure, and an explicit `--tool` call) — these describe expected behavior for
manual/agent-based verification rather than being asserted automatically by `run.sh`.
`--context-benchmark` and `--mcp-live` are excluded from `--all` because they are slower and
require live model access — opt in explicitly.

## Benchmarks

Measured against this bundle's own fixtures (`evals/fixtures/`) with `claude-haiku-4.5` on Kiro
CLI V3 (2.36.0), one representative run:

| Scenario | Lines | Without kirunt | With kirunt | Savings |
|----------|-------|----------------|------------|---------|
| Single large file | 602 | 12,006 tk | 142 tk | 98% |
| Multi-file cross-read | 692 | 12,686 tk | 206 tk | 98% |
| Source + test pair | 90 | 680 tk | 221 tk | 67% |
| Code generation | — | 1,690 tk | 0 tk | 100% |
| MCP call (fixture page) | — | 1,447 tk | 163 tk | 88% |

Overall: **97% savings** across these five scenarios (`bash evals/run.sh --benchmark`).
Token counts are a conservative `chars / 4` estimate; generation output is weighted 5x to
approximate output-token pricing. Your own numbers will vary with file sizes and worker model.
The benchmark now fails loudly if a delegation call returns no answer, instead of silently
reporting 0 tokens and a false 100% saving.

### Cross-checking the estimate against real context-window usage

kiro-cli has no public API or slash command that returns an absolute token count for a given
request: `/usage` reports account-level billing credits, and `/context` reports a context-window
percentage rounded to one decimal — neither is precise enough to score a single fixture file in
isolation, and this is a [known open gap](https://github.com/kirodotdev/Kiro/issues/5760) in the
CLI itself.

At `KIRO_LOG_LEVEL=trace`, the CLI V2 log (`$TMPDIR/kiro-log/kiro-chat.log` on macOS) records an
`EndStream` event per turn with `context_usage_percentage` as an unrounded float — more precision
than the terminal UI ever shows. The same struct has `total_tokens` / `*_input_tokens` /
`output_tokens` fields, but the backend never fills them in; the percentage is the most precise
real signal available there.

CLI V3 moved logs to `~/.kiro/logs/<timestamp>/kiro.log`, and that format does not currently
expose `context_usage_percentage`. `context-benchmark.sh` detects both locations, but on V3 it
reports `n/a` with an explicit warning instead of inventing numbers. This cross-check is
therefore V2-only until a usable V3 usage signal is identified.

`evals/context-benchmark.sh` uses this to cross-check the `chars / 4` estimate above: for each
scenario it runs a throwaway agent twice in an isolated workspace — once with `resources: []`
(baseline, capturing environment noise from globally-installed skills/steering) and once with the
scenario's fixtures declared as `resources` — and takes the delta between the two reported
percentages. That delta, scaled by the model's advertised context window size, approximates the
fixture's real token cost:

| Scenario | chars/4 estimate | Real context-window delta |
|----------|-------------------|----------------------------|
| Single large file | 12,006 tk | ~14,600–14,900 tk |
| Multi-file cross-read | 12,686 tk | ~15,800–15,900 tk |
| Source + test pair | 680 tk | ~850–950 tk |
| Code generation | 2,635 tk | ~2,900–3,600 tk |

Real numbers run consistently ~20–35% higher than the `chars / 4` estimate — expected, since code
(punctuation-heavy, camelCase, symbols) tokenizes closer to chars/3.5–3.8 than chars/4, and the
existing estimate is deliberately conservative. This means the `--benchmark` savings percentages
above are, if anything, an *understatement*.

**Caveats:**
- Reads an undocumented internal log format; a kiro-cli update can change or remove it without
  notice. V3 already lacks the field, so this cross-check is V2-only today (the primary
  `--benchmark` estimate does not depend on it and keeps working either way).
- `KIRO_LOG_LEVEL=trace` logs can contain file paths, code snippets, and command output;
  `context-benchmark.sh` writes them to a scratch `TMPDIR` and deletes it on exit.
- Percentage-of-window is still an approximation of true token count, not an exact figure — but a
  materially closer one than `chars / 4`, since it comes from the backend's own accounting rather
  than a client-side guess.
- Numbers vary a few percent between runs (live model variance) and depend on the model's
  advertised window (`KIRO_CONTEXT_BENCHMARK_WINDOW`, default 200,000, override to match
  `KIRO_CONTEXT_BENCHMARK_MODEL` if you change it from the default `claude-sonnet-4.5`).

## Known limitations

- **No enforcement for code-writer** — only bulk-reader has hook enforcement. code-writer relies
  on the model recognizing when to use it via the skill description.
- **Worker invocation cost** — each delegated call spawns a full `kiro-cli chat` subprocess
  (its own startup, model round trip, and teardown) rather than a lightweight API call. This is
  slower per-call than the original's direct action invocation, though still far cheaper in
  tokens than reading the file directly.
- **stdout cleanup is best-effort** — `kirunt_invoke` strips ANSI escape codes and a leading
  `"> "` prompt-echo prefix from `kiro-cli chat`'s stdout. This matches the current CLI's output
  format; a future `kiro-cli` version changing that format could require updating
  `scripts/lib/kirunt.sh`.
- **No request-size ceiling enforced today** — the message is passed as a CLI argument to
  `kiro-cli chat`, so very large corpora can hit the platform's `ARG_MAX`. Split large reads into
  smaller `--paths` batches if you hit this.

## Credits

kirunt is inspired by [shunt](https://github.com/spotify/portal-ai-plugins/tree/main/plugins/shunt),
the original agent bundle that shunts I/O-heavy work to a cheaper worker model. kirunt adapts that
idea to Kiro CLI.

kirunt is released under the [Apache License 2.0](LICENSE).