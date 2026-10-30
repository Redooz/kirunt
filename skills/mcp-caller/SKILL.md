---
name: mcp-caller
description: Delegate MCP tool calls to a cheaper worker model. Use when a task needs an MCP server (Confluence, AWS docs, GitHub, etc.) and you want the response distilled instead of loaded into your own context.
---

# MCP Caller

kirunt's main agent has no MCP tools in its own `tools` array — `@server/tool` calls are not
available to it directly, on any project, regardless of what's configured. Delegate instead.

Call the script directly (installed location, works from any directory):

```bash
~/.kiro/kirunt/scripts/mcp-call --question "<what you need>"
```

If you are running from a checkout of the kirunt repo instead of a global install, use the
repo-relative path `scripts/mcp-call`.

Or, in an interactive session, invoke it as a skill/slash command:

```
/mcp-caller Search Confluence for the Q3 rollout page and summarize the timeline
```

## Delegation mode: `mcp_caller_mode` (config.json)

There are two ways `mcp-call` can delegate, controlled by `mcp_caller_mode` in
`config.json` (or `~/.kiro/kirunt/config.json` once installed):

- **`worker`** (shipped default) — delegates to `kirunt-mcp-caller`, a dedicated custom agent
  using `includeMcpJson` + `@mcp`. Verified working on Kiro CLI V3 (2.36.0), where MCP tools
  load on demand. It auto-discovers every MCP server configured for the current user/project
  (workspace `.kiro/settings/mcp.json` + global `~/.kiro/settings/mcp.json`).
- **`kiro-default`** — delegates to Kiro's built-in default agent. On CLI V3 built-in agents are
  selected by omitting `--agent`; passing `--agent kiro_default` now errors. This mode is a
  fallback for comparison/testing.

There is no per-invocation override — `mcp-call` always reads whatever `config.json` currently
says, so changing modes is a one-time edit rather than something you set per call.

Either mode still uses the cheap worker model (`worker_model` in config.json, not whatever model
the main session is on) — `kirunt_invoke` passes `--model` uniformly regardless of which agent it
targets. `kiro-default` mode has no kirunt-specific prompt of its own, so the distillation
instructions (bullets-only output, no hallucinating missing servers, report tool failures) travel
in the message sent for that one call instead of living in a dedicated agent config.

The worker resolves the right MCP server/tool itself — you don't need to name a server.
**Do not assume any specific MCP server exists.** What's configured varies per user and per
project — phrase `--question` in terms of the task ("search the wiki for X", "look up AWS docs
on Y"), not a specific server name, unless you already know the exact tool id from a previous
call.

If you already know the exact tool to call (e.g. from a prior delegated call that returned a
matching tool id), skip rediscovery:

```bash
mcp-call --tool "@confluence/conf_search" --args '{"query":"Q3 rollout"}' --question "Summarize the results"
```

`--args` takes inline JSON for small filters. For larger/complex payloads, write the JSON to a
file first and pass `--args-file <path>` instead of hand-escaping it into a shell argument.

Each call is independent — nothing is kept between calls, and MCP servers with session state
(e.g. anything stateful across calls) will not carry that state across separate `mcp-call`
invocations. Ask again with the same `--tool`/`--args` for a follow-up.

## When to use this

- The task needs an MCP server (documentation search, wiki lookup, ticket/issue lookup, etc.)
  and the response could be large (full pages, search result sets, long threads).
- You want a distilled answer rather than the raw MCP response in your own context.

## When NOT to use this

- No MCP servers are configured for this project/user at all — the worker will report this
  cleanly, but there's nothing to delegate to.
- The task needs your own judgment on the result (e.g. deciding whether a search result is
  relevant enough to act on) rather than a factual lookup — delegate the lookup, keep the
  judgment.
- A stateful, multi-step MCP interaction (e.g. an OAuth flow, an elicitation form) — each
  delegated call is a fresh worker session with no memory of prior calls, so this doesn't work
  for anything that needs to maintain state across steps.
