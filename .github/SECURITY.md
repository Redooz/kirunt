# Security policy

## Scope

kirunt is a bash bundle that installs files and runs commands on your machine. Reports in scope
include, but aren't limited to:

- **Install path traversal** — the installer writing outside `KIRUNT_HOME` / `KIRO_HOME`
  (for example via a crafted `KIRUNT_HOME`, a malicious archive, or the remote bootstrap).
- **Archive/checksum bypass** — the `KIRUNT_SHA256` check being skippable, or the extracted
  archive being trusted before validation.
- **Hook bypass** — a payload that reaches a large file read without being blocked, or a hook
  blocking something it shouldn't.
- **Command injection** — a script argument, config value, or file path that escapes into a
  shell unquoted.
- **Credential leakage** — anything that forwards tokens, keys, or session data to a worker
  model or writes them to disk.

## Reporting

Please **do not open a public issue** for a vulnerability. Use GitHub's private reporting:

<https://github.com/Redooz/kirunt/security/advisories/new>

Include the affected script or hook, reproduction steps, and the impact you'd expect.

## What to expect

This is a personal project maintained on a best-effort basis — there's no SLA. Reports are
acknowledged as soon as possible and fixed in a patch release with credit, unless you prefer
to stay anonymous.

## Not a vulnerability

- The main agent delegating to a cheaper model (that's the design).
- Worker model output being imperfect, or a worker failing on an unusual file.
- Anything requiring an already-compromised `kiro-cli`, shell, or user account.
