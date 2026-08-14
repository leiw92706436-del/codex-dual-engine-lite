# Security

Codex Dual Engine Lite is a local, safety-first orchestration kit. It gives a
bounded worker access to a copy of a Git repository and asks an independent
human (or Sol) reviewer to approve the result. Security depends on both the
mechanical controls below and on that human review boundary.

## What this project does and does not do

It does:

- copy a clean Git repository into an isolated, linked worktree;
- scan tracked files for obvious secrets before a model sees them;
- run a configured model through the Codex CLI with a workspace-write sandbox;
- preserve a result package (diff, changed-file list, log, metadata);
- record a human/Sol review verdict without applying anything.

It does not merge, commit, push, cherry-pick, apply patches, or modify the
caller's main worktree. The worker only creates a uniquely named branch and a
linked worktree under the product data directory.

## Reporting a vulnerability

Please report security issues privately to the project maintainer. Do not open
a public issue with a working exploit or a real secret. Include:

- the affected component and version;
- steps to reproduce without real credentials;
- whether any secret, file, or remote state was affected.

## Key security properties

- The API key is read from the macOS Keychain at execution time and is never
  written to disk, printed, or placed in a process argument list.
- `DEEPSEEK_API_KEY` (or the configured `env_key`) is removed from the child
  environment and replaced only with the Keychain value for the model process.
- The main worktree is never the working root of the model; only the linked
  worktree is.
- Secret preflight is fail-closed and runs before the model command.
- The model runs under `--sandbox workspace-write` (or `read-only`), never
  `danger-full-access`, and never
  `--dangerously-bypass-approvals-and-sandbox`.

## Threats and mitigations

See [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md) for the full threat model.
The main classes are:

- prompt injection from repository content;
- secret exposure through files, logs, argv, or environment;
- malicious or symlinked paths;
- command/task injection;
- log leakage;
- over-broad sandbox or approval settings;
- complete but untrusted patches or diffs;
- the absence of independent human/Sol review.

## Operational guidance

- Keep the product data directory private (`chmod 700`). It contains result
  packages and logs.
- Treat `diff.patch`, retry `after.patch`/`delta.patch`, and any model-produced
  files as untrusted input. The
  patch is intended to be complete (tracked, staged, deleted, renamed, and
  untracked new files, including binary content), but completeness does not
  make it safe to apply.
- Never commit a `config.toml` that contains a real secret.
- Review every result package independently before applying anything.
