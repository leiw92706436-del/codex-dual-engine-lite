# Cost control and harness A/B plan

## Objective

Minimize GPT Plus/Sol usage without weakening independent review. DeepSeek may
do the implementation work, but Sol should not consume the model's live
transcript. Sol reviews only a small, locally verified result packet after the
worker becomes idle.

## Target workflow

```text
Sol writes one bounded task
        |
        v
DeepSeek runs quietly in an isolated worktree
        |
        v
local worker computes REVIEW_PACKET.json
        |
        v
Sol reviews by risk: GREEN / YELLOW / RED
        |
        v
PASS / one delta-only RETRY / TAKEOVER
```

The worker report is an index, not proof. File lists, patch hashes, exit codes,
budget state, and main-worktree cleanliness must be computed locally rather
than copied from the model's final answer.

## Cost controls

- Do not stream model reasoning, commands, test output, or diffs to Sol.
- Keep the complete model transcript in a private `worker.log`; expose only the
  task id and short worker status on stderr.
- Stop a run when its wall-clock or log-size budget is exceeded.
- Flag post-run patch-size and changed-file-count budget violations in the
  review packet.
- Run focused tests while developing. Allow one final full suite from the
  worker and one independent suite from Sol.
- A RETRY is limited to one focused correction. Sol reviews only the retry
  delta plus affected tests, not the complete live transcript again.
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

## Risk-based Sol review

| level | typical changes | minimum review |
| --- | --- | --- |
| GREEN | documentation, formatting, comments | local checks and sampled hunks |
| YELLOW | ordinary application logic and tests | all changed hunks and relevant tests |
| RED | shell execution, auth, secrets, networking, permissions, deletion, installers, CI/infrastructure | all security-critical hunks and independent validation |

Risk classification is conservative. A locally generated recommendation may
raise review depth but never grants approval. Sol owns the final verdict.

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

## DeepSeek Harness experiment

DeepSeek Harness remains an experiment while it is in developer preview. Do
not replace the default Codex CLI engine based on one run.

Compare an optimized Codex CLI worker with Harness headless using cloned copies
of the same synthetic repository, the same model, prompt, sandbox boundary,
budget, and reviewer. Record:

- input, output, and cache tokens when available;
- model and tool-call counts;
- repeated model-visible diff bytes;
- wall time and budget stops;
- task/test success;
- Sol review effort and findings;
- argv, persistence, sandbox, credential, and log exposure.

Use a medium fixture that creates and modifies several files. Cap each arm at
300,000 model tokens when supported, otherwise at the same runtime and log
budgets. A single run is a smoke test only. Consider migration only after
Harness wins three different tasks while reducing model tokens by at least 50%
and Sol review usage by at least 60%, without lowering quality or safety.

## First controlled smoke result (2026-08-15)

The first A/B used DeepSeek V4 Pro at high reasoning on two clones of the same
small Python fixture. Both arms received the same bounded task, allowed paths,
acceptance criteria, and validation command. Both were externally limited to
180 seconds and 524,288 bytes of run/session growth.

| arm | result | time | reported token signal | independent review |
| --- | --- | ---: | ---: | --- |
| optimized Codex CLI worker | completed; 10 tests passed | about 63 s | 17,073 aggregate CLI tokens | `RETRY`: two generated `__pycache__` files exceeded scope |
| Harness, 2,048 output/request | stopped at `max-tokens`; no changes | 33.6 s | 8,406 uncached input + 16,000 cache read + 2,380 output | `FAIL`: cap was too low for V4 Pro coding |
| Harness, 8,192 output/request | completed; 9 tests passed | 53.6 s | 2,149 uncached input + 83,072 cache read + 4,089 output | `RETRY`: the same `__pycache__` scope violation |

The token figures are not directly equivalent: Codex CLI emitted one aggregate
number, while Harness exposed provider usage buckets for every request. Even
with that caveat, this smoke provides no evidence that Harness reduces total
model-visible context. Most Harness input was cache-read traffic, so it may be
cheap, but it was still repeated context.

The review-cost change did work: Sol did not watch either live transcript. It
read the compact packet/status first, inspected one completed diff at the
required YELLOW depth, and ran one independent test suite. That was sufficient
to catch the out-of-scope generated files in both implementations.

### Decision

- Keep the optimized Codex CLI worker as the default engine.
- Do not migrate to Harness from this smoke result.
- Do not spend tokens completing the three-task migration threshold unless a
  later Harness release adds a reliable total-task token budget or materially
  changes context behavior.
- Keep Harness as an explicit, isolated experiment only.
