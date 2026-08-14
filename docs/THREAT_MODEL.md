# Threat model

This document describes the threat model for Codex Dual Engine Lite v0.2. The
trust boundary is between the local operator, the delegated model, repository
content, the macOS Keychain, and the independent human/Sol reviewer.

## Assets

- The caller's main Git worktree and its history.
- The configured API key stored in the macOS Keychain.
- The product data directory (result packages, logs, metadata).
- The operator's shell session and local filesystem.

## Actors

- **Operator**: runs the CLI and reviews results. Assumed trusted.
- **Delegated model**: untrusted; it can produce arbitrary file changes and
  prompt text.
- **Repository content**: untrusted; it may be a prompt-injection vector.
- **Human/Sol reviewer**: independent and trusted, but may make mistakes.

## Threats

### 1. Prompt injection from repository content

Repository files are read by the model and may contain instructions intended to
escape the bounded task, exfiltrate data, or cause harmful tool calls.

Mitigations:

- The model works in an isolated linked worktree, not the main worktree.
- The model runs inside a workspace-write (or read-only) sandbox.
- There is no default approval bypass or `danger-full-access`.
- Automatic approvals are opt-in and still sandboxed.
- Nothing is merged or pushed; a human/Sol reviewer inspects the diff.

Residual risk: a sufficiently capable model may still attempt to write files
inside the worktree, print secrets it can read from the worktree, or request
approval for actions. The review gate is the final control.

### 2. Secret exposure

The API key could leak through logs, argv, environment, generated config, or a
stale `DEEPSEEK_API_KEY` inherited from the parent process.

Mitigations:

- The key is fetched from Keychain with `security find-generic-password -w` and
  is never echoed, logged, or written to disk.
- `DEEPSEEK_API_KEY` (and the configured `env_key`) is unset before exec and
  injected only for the model process via `export`, not argv.
- The generated Codex CLI config contains no secret.
- Log files are created with mode 0600 inside a 0700 data directory.
- Secret preflight blocks repository files containing high-confidence secrets
  before the model runs.

Residual risk: a process with the same user can observe environment variables
or Keychain items. The Keychain itself may be unlocked by the user.

### 3. Malicious paths and symlinks

An attacker who can influence the task id, data directory, or filesystem could
cause the tool to write outside the product data directory or follow a symlink.

Mitigations:

- Task ids are strictly validated (`[A-Za-z0-9][A-Za-z0-9._-]{0,127}`) and
  reject `..` and leading dots.
- Review and clean reject symlinked path components and verify that resolved
  paths stay inside the data directory.
- Clean verifies the worktree/branch relationship with `git worktree list`
  before removing anything, and removes only exact managed paths.

Residual risk: a same-user local attacker can generally do anything the user
can; these controls mainly defend against path-injection and operator error.

### 4. Command/task injection

Task text, config values, or filenames could be interpreted as shell syntax.

Mitigations:

- Task text is passed as a data argument to stdin, never `eval`-ed.
- Config values are quoted when written back into generated config.
- Filenames are used with `--` and quoted where commands require it.
- The worker does not `eval` task text or repository content.

Residual risk: Bash string handling is error-prone; the suite exercises the
main injection cases but cannot be exhaustive.

### 5. Log leakage

Logs could contain the task text, repository content, or secret-matching lines.

Mitigations:

- Preflight diagnostics print only repository-relative filenames and rule
  names, never matching values or full matching lines.
- The worker log is mode 0600 and does not log Keychain values.

Residual risk: model output is captured in the worker log and may itself
contain repository content or a secret the model reproduced. Reviewers should
treat logs as sensitive.

### 6. Over-broad sandbox or approvals

Misconfiguration could enable full filesystem access or approval bypass.

Mitigations:

- `danger-full-access` is rejected by `codex-ds`.
- `--dangerously-bypass-approvals-and-sandbox` is never emitted.
- `auto_approve = true` maps to `--approve-for-me` (workspace-write sandbox),
  and is off by default.

Residual risk: an operator can still run the underlying Codex CLI directly with
broader settings; this tool does not replace OS-level controls.

### 7. Untrusted patches and diffs

`diff.patch` is a complete patch against HEAD: it includes tracked, staged,
deleted, renamed, and untracked new files, with binary content preserved in
Git binary-patch form. It and the changed-file list are model output and must
not be applied without review. Completeness improves auditability but does not
make the patch trusted.

Mitigations:

- The worker never applies patches or merges anything.
- `deepseek-worker-review` only records a verdict.
- `deepseek-worker-clean` only removes the managed worktree/branch and always
  preserves the result package.

Residual risk: an operator may manually apply an untrusted diff; that is an
out-of-band action.

### 8. Independent human/Sol review boundary

The product is only safe if an independent party reviews results.

Mitigations:

- Review recording is a separate command with an explicit verdict.
- The tool does not claim to perform automatic Sol reasoning or merging.

Residual risk: the tool cannot verify that a human actually read the diff.
