# Cost control

## Objective

Keep the independent Codex/Sol reviewer out of the model's live transcript.
DeepSeek V4 Pro may do the implementation work through `codex-ds`, but the
delegated model's output is untrusted. The reviewer reads a small, locally
computed result packet after the worker becomes idle, then decides `PASS`,
`RETRY`, or `TAKEOVER`.

This document is a cost-control and review protocol. It is not a routing layer
and does not make DeepSeek Harness the default engine.

## Target workflow

```text
Independent Codex/Sol reviewer writes one bounded task
        |
        v
DeepSeek V4 Pro runs quietly in an isolated worktree
        |
        v
local worker computes REVIEW_PACKET.json
        |
        v
Codex/Sol reviews by risk: GREEN / YELLOW / RED
        |
        v
PASS / one delta-only RETRY / TAKEOVER
```

The worker report is an index, not proof. File lists, patch hashes, exit codes,
budget state, and main-worktree cleanliness are computed locally rather than
copied from the model's final answer.

## Cost controls

- Do not stream model reasoning, commands, test output, or diffs to the
  independent reviewer.
- Keep the complete model transcript in a private `worker.log`; expose only the
  task id and short worker status on stderr.
- Stop a run when its wall-clock or log-size budget is exceeded.
- Flag post-run patch-size and changed-file-count budget violations in the
  review packet.
- Run focused tests while developing. Allow one final full suite from the
  worker and one independent suite from the reviewer.
- Limit a `RETRY` to one focused correction. Review only the retry delta plus
  affected tests, not the complete live transcript again.
- Do not include a full patch in either model's final message. Store it as an
  artifact and identify it by path, size, and SHA-256.

Default safety budgets are deliberately conservative and configurable:

| control | default |
| --- | ---: |
| maximum runtime | 1,800 seconds |
| maximum private worker log | 2,000,000 bytes |
| maximum changed files | 100 |
| maximum patch size | 5,000,000 bytes |

These are operational circuit breakers, not exact API-token meters. The Codex
CLI does not currently expose a reliable per-task token kill switch to this
wrapper, so log growth and elapsed time are used as bounded proxies.

For a normal bounded implementation, a conservative single-task profile is
600 seconds, 600,000 private-log bytes, up to 20 changed files, and a
2,000,000-byte patch. Keep implementation and directly affected tests together
when they are one coherent deliverable. Use shorter profiles only for explicit
smoke tests.

## Risk-based Codex/Sol review

| level | typical changes | minimum review |
| --- | --- | --- |
| GREEN | documentation, formatting, comments | local checks and sampled hunks |
| YELLOW | ordinary application logic and tests | all changed hunks and relevant tests |
| RED | shell execution, auth, secrets, networking, permissions, deletion, installers, CI/infrastructure | all security-critical hunks and independent validation |

Risk classification is conservative. A locally generated recommendation may
raise review depth but never grants approval. Codex/Sol owns the final verdict.

## Fixed review packet

Every completed worker run writes `REVIEW_PACKET.json` with a stable schema:

- task and base-commit identity;
- model exit status and whether files changed;
- locally computed changed-file count, patch size, and patch SHA-256;
- main-worktree cleanliness;
- configured budgets and any stop reason;
- conservative risk level and review recommendation;
- explicit `NOT_RUN_BY_REVIEWER` validation state.

The packet must never contain credentials, model reasoning, source-code
contents, or full test logs.

## One controlled retry

A `RETRY` verdict permits exactly one correction in the existing isolated
worktree. The correction file must contain only the failed acceptance
criterion and required delta:

```sh
deepseek-worker-retry prepare TASK_ID --task-file correction.txt
deepseek-worker-retry execute TASK_ID
```

Preparation never invokes a model. Execution uses a fixed concise response
contract plus independent runtime/log circuit breakers. It publishes a private
`EXECUTION.json`, complete `after.patch`, and a locally reconstructed
`delta.patch`. The reviewer reads the execution packet first, then reviews only
the delta and reruns the previously failing validation. Final `PASS`
independently reconstructs both the current after-state and before-to-after
delta. Failed, stopped, incomplete, drifted, or tampered retry packages fail
closed; a second `RETRY` is refused.

## DeepSeek Harness comparison boundary

DeepSeek Harness is not the default engine and is not part of this repository.
It may be compared manually while it is in developer preview, but only as an
isolated, budgeted experiment. Do not replace the default Codex CLI engine
based on one run.

If comparing, use cloned copies of the same synthetic repository and hold
constant the model, prompt, sandbox boundary, budget, and reviewer. Record:

- input, output, and cache tokens when available;
- model and tool-call counts;
- repeated model-visible diff bytes;
- wall time and budget stops;
- task/test success;
- reviewer effort and findings;
- argv, persistence, sandbox, credential, and log exposure.

Cap each arm at the same token budget when supported, otherwise at the same
runtime and log budgets. A single run is a smoke test only. Consider a change
only after Harness wins multiple different tasks with materially lower total
model-visible context and reviewer usage, without lowering quality or safety.

This repository provides no automatic routing, migration, or background queue
for Harness. Any comparison is an explicit manual action.

## Historical measurements

A controlled smoke test on 2026-08-15 compared the optimized Codex CLI worker
with Harness at two output/request caps on cloned copies of the same small
Python fixture. Each arm received the same bounded task, allowed paths,
acceptance criteria, and validation command, and was externally limited to
180 seconds and 524,288 bytes of run/session growth.

| arm | result | time | reported token signal | independent review |
| --- | --- | ---: | ---: | --- |
| optimized Codex CLI worker | completed; 10 tests passed | about 63 s | 17,073 aggregate CLI tokens | `RETRY`: two generated `__pycache__` files exceeded scope |
| Harness, 2,048 output/request | stopped at `max-tokens`; no changes | 33.6 s | 8,406 uncached input + 16,000 cache read + 2,380 output | `FAIL`: cap was too low for V4 Pro coding |
| Harness, 8,192 output/request | completed; 9 tests passed | 53.6 s | 2,149 uncached input + 83,072 cache read + 4,089 output | `RETRY`: the same `__pycache__` scope violation |

The token figures are not directly equivalent: Codex CLI emitted one aggregate
number, while Harness exposed provider usage buckets for every request. Even
with that caveat, this smoke provides no evidence that Harness reduces total
model-visible context; most Harness input was cache-read traffic, so it may be
cheap but was still repeated context.

Three narrowly scoped Codex CLI/V4 implementation tasks were each capped at
300 seconds and one changed file. All three timed out but left useful partial
work. That evidence led to the 600-second coherent-task policy, and the
completed local suite has 276 passing checks.
