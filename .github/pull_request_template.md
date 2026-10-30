## What changed

<!-- One or two sentences. Link the issue if there is one. -->

## Which layer

- [ ] Hook
- [ ] Script (`bulk-read` / `code-write` / `mcp-call`)
- [ ] Skill guidance
- [ ] Config / installer
- [ ] Docs

## Checklist

- [ ] `bash evals/run.sh` passes (79 offline cases)
- [ ] `bash evals/config-evals.sh` passes
- [ ] Tunable defaults updated in all three places if I added or changed one
      (`config.json`, `scripts/lib/kirunt.sh`, eval expectations)
- [ ] Design invariants respected (see [CONTRIBUTING.md](../CONTRIBUTING.md))
- [ ] `README.md` and `README_ES.md` both updated for user-facing changes
