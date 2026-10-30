# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-10-30

First public release.

### Added

- **Bulk reading** — `hooks/check-file-size` blocks direct reads of large files and redirects to
  the `bulk-reader` skill, which delegates through `scripts/bulk-read` to the tool-less
  `kirunt-bulk-reader` worker agent. Works with both Kiro CLI V3 (`read_file` with
  `offset`/`limit`) and V2 (`operations[]`) payloads.
- **Shell-read blocking** — `hooks/check-bash-read` catches large reads attempted through
  `execute_bash` / shell commands.
- **Boilerplate generation** — `scripts/code-write` delegates to the `kirunt-code-writer` worker.
- **MCP delegation** — `scripts/mcp-call` routes MCP tool calls to `kirunt-mcp-caller`, with
  two modes: `worker` (custom agent) and `kiro-default` (Kiro's built-in default agent, for the
  V2 engine).
- **Single-file configuration** — `config.json` holds every tunable (`worker_model`,
  `min_lines`, `timeout_seconds`, feature flags, `mcp_caller_mode`); no env-var overrides.
- **Global installer** — `install/install.sh` installs to `~/.kiro/kirunt` and
  `~/.kiro/agents`, derives the installed agent config from `agents/kirunt.json`, validates
  every config with `kiro-cli agent validate`, and is idempotent. Supports `--uninstall`,
  `--mcp-caller-mode`, `KIRUNT_HOME`, `KIRUNT_VERSION`, and `KIRUNT_SHA256`.
- **Curl bootstrap** — the same installer works piped from `curl`, downloading a branch or tag
  archive from GitHub.
- **Offline eval suite** — 79 cases covering hook routing (V2 + V3 payloads), the `kirunt_invoke`
  transport layer, and `mcp-call` argument validation, plus a 7-case config-loading suite.
- **Live benchmarks** — `--benchmark` estimates token savings against the real worker model,
  `--context-benchmark` cross-checks against `kiro-cli`'s own context accounting, and
  `--mcp-live` exercises the MCP worker against a fixture server.
- **Docs** — English and Spanish READMEs.

[Unreleased]: https://github.com/Redooz/kirunt/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Redooz/kirunt/releases/tag/v0.1.0
