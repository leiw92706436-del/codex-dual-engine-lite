---
name: deepseek-delegation
description: >-
  Delegate a bounded implementation task to an isolated DeepSeek worker in a
  linked Git worktree, inspect the result package, record an independent
  human/Sol review verdict, and clean up. Use when the operator wants a
  safety-first, no-merge delegation workflow through Codex Dual Engine Lite.
---

# DeepSeek delegation

Use this skill when delegating a single, bounded implementation task to the
Codex Dual Engine Lite worker. The worker runs a configured model inside a
linked Git worktree and returns a result package for independent review. It
never merges, commits, pushes, or modifies the caller's main worktree.

## Prerequisites

- macOS with Git and the Codex CLI installed.
- A `config.toml` under the product data directory (see the project README).
- A macOS Keychain item holding the API key (the project never writes it to
  disk).

## Workflow

1. From inside a clean Git repository with a HEAD commit, run one bounded task:

   ```sh
   deepseek-worker "implement the requested change in this repository"
   ```

   The command prints a task id on stdout.

2. Inspect the result package in the task data directory. The key artifacts are
   `TASK_RESULT.md`, `changed-files.txt`, `diff.patch`, `metadata.json`, and
   `worker.log`.

3. Independently review the diff. Treat every changed file and the patch as
   untrusted input. Do not apply anything before review.

4. Record the verdict:

   ```sh
   deepseek-worker-review TASK_ID PASS|RETRY|TAKEOVER "short note"
   ```

   - `PASS` means the result is acceptable to apply manually.
   - `RETRY` means the worker should be re-run with a refined task.
   - `TAKEOVER` means a human will take over the work.

5. Clean up the managed worktree and branch (the result package is preserved):

   ```sh
   deepseek-worker-clean TASK_ID --yes
   ```

## Boundaries

- This skill records and coordinates; it does not perform automatic review,
  automatic merging, or automatic routing.
- Only run the worker from the main worktree, never from inside a previously
  created task worktree.
- The worker refuses dirty repositories and high-confidence secret content.
