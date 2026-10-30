---
name: code-writer
description: Delegate boilerplate code generation to a cheaper worker model. Use for tests, config, docstrings, type stubs, or any generation where >80% is predictable from reference files.
---

# Code Writer

Delegate boilerplate generation instead of writing it all yourself when most of the output is
predictable from an existing reference file.

Call the script directly (installed location, works from any directory):

```bash
# Generate and write directly to a target file
~/.kiro/kirunt/scripts/code-write --spec "<what to generate>" --reference <reference-file> --target <output-path>

# Output to stdout instead (omit --target)
~/.kiro/kirunt/scripts/code-write --spec "<what to generate>" --reference <reference-file>
```

If you are running from a checkout of the kirunt repo instead of a global
install, use the repo-relative path `scripts/code-write`.

Or, in an interactive session, invoke it as a skill/slash command:

```
/code-writer Write tests for UserService, reference tests/OrderTest.ts, target tests/UserTest.ts
```

`--reference` is required — without a file to match patterns against, the worker generates
context-free code that fits nothing in the project. Each call is independent; to build on what
was just generated, pass that file as the `--reference` for the next call.

## When to use this

- Generating tests, config stubs, docstrings, or type stubs where the shape is >80% predictable
  from an existing reference file.
- The output is boilerplate the model would otherwise spend a lot of your context re-deriving.

## When NOT to use this

- There is no good reference file — the worker has nothing to match patterns against.
- The task needs your own judgment (non-trivial logic, architectural decisions, anything with
  real design tradeoffs).

Review the output and make surgical edits for the remaining ~5-20% that needs your judgment.
There is no hook enforcing use of this skill — unlike bulk-reader, nothing blocks you from
writing the code yourself, so this is a suggestion, not a gate.
