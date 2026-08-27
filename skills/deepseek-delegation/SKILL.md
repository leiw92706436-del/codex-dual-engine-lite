---
name: deepseek-delegation
description: Delegate one bounded coding task to the existing DeepSeek V4 Pro worker in an isolated Git worktree, perform a cost-bounded independent review by the supervising Codex or human, and optionally execute exactly one reviewed delta-only retry without merging. Use only when the user explicitly asks for DeepSeek, V4 Pro, Dual Engine B-lite, or this skill. Do not use for automatic routing, secrets, production writes, destructive actions, or unclear requirements.
---

# DeepSeek Delegation

Use the installed `deepseek-worker` for one bounded implementation task. The
worker creates an isolated worktree and a locally computed review packet. It
never commits, merges, cherry-picks, pushes, or changes the caller's main
worktree.

The main objective is to move one bounded implementation pass to an external
worker without accepting the worker's self-report as proof. This may reduce
supervisor usage, but it does not guarantee lower total cost.

## Prepare one bounded task

Before delegation:

1. Confirm the current directory is the intended Git repository and its main
   worktree is clean. Stop if dirty; do not stash or commit user changes.
2. Reject tasks requiring secrets, credentials, production access, external
   writes, destructive actions, multiple repositories, or unresolved product
   decisions.
3. State the objective, allowed scope, exclusions, acceptance criteria, and
   validation commands.
4. Keep the task self-contained and coherent. Include implementation and its
   directly affected tests in one delegation when they form one deliverable;
   do not split them into artificial one-file fragments merely to reduce V4
   usage. Do not ask the worker to explore unrelated architecture or redesign
   the project.
5. Never print, inspect, or copy secret values.

## Run quietly

For implementation work, keep supervisor context usage bounded. Give V4 Pro up
to 600 seconds and enough file/patch room for a coherent implementation plus
its direct tests:

```sh
CODEX_DUAL_ENGINE_LITE_MAX_RUNTIME_SECONDS=600 \
CODEX_DUAL_ENGINE_LITE_MAX_LOG_BYTES=600000 \
CODEX_DUAL_ENGINE_LITE_MAX_CHANGED_FILES=20 \
CODEX_DUAL_ENGINE_LITE_MAX_PATCH_BYTES=2000000 \
deepseek-worker "<bounded task>"
```

The wrapper has no reliable model-token kill switch. The 600-second runtime is
the enforceable doubled budget; log bytes are only a secondary circuit
breaker, not a token count. Use a shorter 300-second profile only for an
explicit smoke test or A/B experiment, not for normal V4 implementation.

Let the command finish and retain only its short status output and task ID.
Do not stream, summarize, or repeatedly inspect model reasoning, commands,
tests, diffs, or `worker.log` while it runs. If the command becomes a
background terminal session, poll only for completion; do not read its live
transcript. Do not begin a competing supervisor implementation while V4 is
still within the 600-second budget.

A worker exit code of zero means the result package was created. It is not a
review verdict.

Stop without approving when:

- the worker did not create a complete result package;
- `REVIEW_PACKET.json` says a budget was exceeded;
- the model exit status is nonzero;
- the main worktree is no longer clean;
- changed files exceed the delegated scope.

Do not rebuild the worker, alter Keychain authentication, or switch runtimes
as an automatic recovery step.

## Review the fixed packet first

Read `REVIEW_PACKET.json` before any large artifact. Verify its local facts:

- task ID and base commit;
- model exit status;
- changed-file count;
- patch size and SHA-256;
- main-worktree cleanliness;
- budget state;
- risk level and recommended review depth.

Treat all model output as untrusted. The fixed packet is locally computed and
may select review depth, but it can never approve the patch.

Only read `TASK_RESULT.md` for orientation. Do not read the entire
`worker.log` unless the packet reports failure or a targeted diagnostic is
needed; then inspect only a short relevant tail or matching lines.

## Apply risk-based independent review

Always inspect the real worktree and recompute enough evidence to verify the
packet. Review only once at the depth selected below:

- **GREEN**: documentation/tests-only. Confirm scope, inspect sampled hunks,
  run the relevant local checks, and check the main repository is untouched.
- **YELLOW**: application logic. Inspect every changed hunk, run relevant
  tests, and exercise the changed behavior.
- **RED**: security, authentication, permissions, networking, installation,
  executable scripts, CI, or configuration. Inspect every security-critical
  hunk and independently validate failure paths and safety boundaries.

Escalate the depth whenever local evidence is riskier than the packet's
classification. Never downgrade it based on the worker's prose.

Prefer concise validation output: exit code, failing test names, and aggregate
counts. Do not feed successful full test logs or the full patch back into the
reviewer context when direct local inspection is available.

## Record exactly one verdict

Use the installed recorder:

```sh
deepseek-worker-review TASK_ID PASS|RETRY|TAKEOVER "short evidence-based note"
```

- `PASS`: the implementation, scope, packet integrity, and independent
  validation satisfy the task.
- `RETRY`: one narrow V4 Pro correction is worthwhile.
- `TAKEOVER`: the supervising Codex or human should finish the work, or a user
  decision is required.

For `RETRY`, allow at most one delta-only correction. State the failing
acceptance criterion and implicated files; do not resend the full transcript
or ask for a broad reimplementation. Put that correction in a private local
file, prepare it, then execute with the same doubled time/log profile:

```sh
deepseek-worker-retry prepare TASK_ID --task-file CORRECTION_FILE
CODEX_DUAL_ENGINE_LITE_RETRY_MAX_RUNTIME_SECONDS=600 \
CODEX_DUAL_ENGINE_LITE_RETRY_MAX_LOG_BYTES=600000 \
deepseek-worker-retry execute TASK_ID
```

The execute step is quiet and budgeted. Read `EXECUTION.json` first. Stop with
`TAKEOVER` if it is missing, malformed, not `COMPLETE`, reports a nonzero
runner exit, or reports a budget stop. Otherwise verify its hashes and counts,
inspect only `delta.patch` and `delta-files.txt`, and rerun only the previously
failing validation. Record final `PASS` with `deepseek-worker-review`; its
fail-closed gate independently reconstructs the current after-state and retry
delta. Never run a second retry. If the correction still fails, use
`TAKEOVER`.

Report a compact final summary: task ID, risk level, changed files, validation,
findings, verdict, and next action.

## Preserve B-lite boundaries

- Never automatically apply, merge, commit, cherry-pick, push, or clean a real
  task worktree.
- Use `deepseek-worker-clean TASK_ID --yes` only when the user explicitly
  authorizes cleanup or for an explicitly disposable test.
- Do not introduce automatic routing, background queues, multi-worker
  orchestration, or production migration to another harness.
- DeepSeek Harness, Claude Code, and Luna are experiment-only candidates. Run
  them only when the user explicitly asks for a bounded comparison, with the
  same task and hard runtime/output budgets.
