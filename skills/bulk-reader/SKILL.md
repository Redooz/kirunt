---
name: bulk-reader
description: Delegate bulk file reading to a cheaper worker model. Use when you need to read files >350 lines, answer questions across 3+ files, or summarize large diffs.
---

# Bulk Reader

When a `PreToolUse` hook blocks a `read` or `cat`/`head`/`tail` call because the file is over
the line threshold, or when you need to read/summarize several files at once, delegate the read
instead of chunking through it yourself with offset/limit.

Call the script directly (installed location, works from any directory):

```bash
~/.kiro/kirunt/scripts/bulk-read --question "<question>" --paths <file1> [<file2> ...]
```

If you are running from a checkout of the kirunt repo instead of a global
install, use the repo-relative path `scripts/bulk-read`.

Or, in an interactive session, invoke it as a skill/slash command:

```
/bulk-reader What does this file do? src/foo.ts
```

Each call is independent — nothing is kept between calls. To ask a follow-up, ask again with
the same `--paths`; the files go to the worker model, never into your own context, so
re-sending them costs you nothing extra where it matters (your context budget).

## When to use this

- A file exceeds the line threshold (`min_lines` in config.json, default 350) and you were
  blocked from reading it directly.
- You need an answer that spans 3+ files (cross-service question, wide diff, etc.).
- You want a structural summary (functions, classes, call sites) rather than the raw content.

## When NOT to use this

- You need exact line numbers or exact text to make an edit — use a targeted `read` with
  `offset`/`limit` instead, or verify specific values before using them in edits.
- The file is small — delegation overhead isn't worth it under the threshold.
- The task requires your own reasoning (debugging, architectural judgment) rather than a summary.
