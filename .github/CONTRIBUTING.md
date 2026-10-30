# Contributing to kirunt

kirunt is a bash-only bundle: `hooks/` block large reads, `scripts/` delegate to worker agents
via `kiro-cli chat`, and `skills/` tell the main model when to call those scripts. There is no
build step.

## Before you open a PR

```bash
bash evals/run.sh            # 79 offline cases — must all pass
bash evals/config-evals.sh   # config.json loading/fallback suite
```

Both need only `bash` and `jq`; neither needs model access. CI runs the same two commands, plus
a `bash -n` syntax pass.

If your change touches the MCP worker prompt or `mcp_caller_mode`, also run the live suite — it
needs `node`, `kiro-cli`, and model access:

```bash
bash evals/run.sh --mcp-live
```

## Ground rules

- **Keep it bash.** No new runtime dependencies beyond `bash`, `jq`, and `kiro-cli`.
- **Hooks stay profile-scoped.** They are installed into the `kirunt` agent config, never as
  global `~/.kiro/hooks/*.json` — that would block large reads for every agent on the machine.
- **One switch per capability.** `enable_bulk_reader` is read by both hooks and `bulk-read`.
  Never disable a capability by editing only one side; flip the flag.
- **Tunables live in `config.json`.** No new env-var overrides — `scripts/lib/kirunt.sh` loads
  and validates every setting in one place.
- **Worker agents stay minimal.** `kirunt-bulk-reader` and `kirunt-code-writer` are deliberately
  tool-less. Don't grant workers extra tools.
- **Tunable defaults are duplicated in three places** (`config.json`, the fallbacks in
  `kirunt.sh`, and eval expectations). Update them together.
- If you change user-facing behavior, update both `README.md` and `README_ES.md`.

## Commit messages

Short imperative subject line, then a body explaining the *why* when it isn't obvious.

## Reporting bugs

Open an issue with your `kiro-cli --version`, `kiro-cli settings list` output, and the relevant
`config.json`. Security-sensitive reports go through [`SECURITY.md`](SECURITY.md) instead.
