# Codex Dual Engine Lite

A small, safety-first orchestration kit for delegating a bounded task to a
DeepSeek model through the Codex CLI, while keeping the caller's main worktree
untouched and requiring independent human/Sol review before anything is used.

```text
Codex / Sol
    |
    v
bounded DeepSeek V4 Pro worker  -->  isolated Git worktree
    |                                     |
    |        (never commits, merges,      |
    |         pushes, or patches)         |
    v                                     v
result package + diff               independent Sol review
```

This is a **v0.2 local implementation**. It is not a routing layer, a retry
manager, or a review automaton. It does not merge anything and does not claim
to be production-hardened.

## What it does and does not do

It does:

- copy a clean Git repository into an isolated, linked worktree under the
  product data directory;
- run a fail-closed secret preflight before the model sees any files;
- invoke the model through the Codex CLI with a `workspace-write` sandbox;
- preserve an auditable result package (diff, changed-file list, metadata, log);
- record an independent human/Sol review verdict as a separate action, with a
  fail-closed PASS gate that verifies the local result invariants before
  recording `PASS`;
- clean up only the managed worktree and branch while preserving results.

It does **not**:

- merge, commit, cherry-pick, push, or apply patches;
- modify the caller's main worktree;
- use `danger-full-access` or
  `--dangerously-bypass-approvals-and-sandbox`;
- route tasks automatically, retry failed tasks, perform automatic Sol
  reasoning, or merge on approval;
- publish anything remotely or ship telemetry.

## Compatibility

- **OS:** macOS. POSIX-ish Bash is used, but the tool is tested on macOS and
  relies on `security(1)` for the macOS Keychain.
- **Shell:** Bash 3.2 or newer (the macOS system Bash is sufficient).
- **Codex CLI:** any recent Codex CLI that supports
  `codex exec --sandbox read-only|workspace-write` and
  `--approve-for-me`. Development and tests were performed against Codex CLI
  0.147.0, but no version is hard-coded as the only supported one.
- **Git:** a Git version that supports `git worktree` and
  `git worktree list --porcelain`.

## Repository layout

```text
bin/                         shipped CLI scripts
  codex-ds                   model entrypoint (isolated CODEX_HOME + Keychain)
  deepseek-worker            bounded task -> isolated worktree -> result package
  deepseek-worker-review     records PASS|RETRY|TAKEOVER
  deepseek-worker-clean      removes only the managed worktree and branch
  deepseek-worker-doctor     read-only diagnostics
config/config.example.toml   example configuration (copy and edit)
skills/deepseek-delegation/  Codex skill for the delegation workflow
agents/openai.yaml           optional agent reference (not installed by default)
docs/THREAT_MODEL.md         threat model
docs/COST_CONTROL_AND_AB.md  cost controls and harness experiment protocol
SECURITY.md                  security notes and reporting
install.sh                   idempotent installer
uninstall.sh                 removes only exact installed files
tests/run_tests.sh           offline automated test suite
```

## Data directory and configuration

All generated state lives under a product-specific data directory. Its default
is:

```text
$HOME/.local/share/codex-dual-engine-lite/
```

Override it with `CODEX_DUAL_ENGINE_LITE_HOME`. The configuration file defaults
to `$CODEX_DUAL_ENGINE_LITE_HOME/config.toml` and can be overridden with
`CODEX_DUAL_ENGINE_LITE_CONFIG`.

No credentials are stored in the config file. The API key is kept only in the
macOS Keychain and read at execution time.

## Prerequisites

- macOS
- Bash 3.2+
- Git
- the Codex CLI on `PATH` (or set `CODEX_DUAL_ENGINE_LITE_CODEX`)
- `security(1)` (ships with macOS)

## Installation

From a checkout of this repository:

```sh
./install.sh
```

Default destinations:

| artifact | destination |
| --- | --- |
| CLI scripts | `$HOME/.local/bin` |
| delegation skill | `$CODEX_HOME/skills/deepseek-delegation/SKILL.md` |
| example config | `$CODEX_DUAL_ENGINE_LITE_HOME/config.toml` (only if absent) |

Environment overrides:

| variable | purpose |
| --- | --- |
| `CODEX_DUAL_ENGINE_LITE_PREFIX` | base prefix (default `$HOME/.local`) |
| `CODEX_DUAL_ENGINE_LITE_BIN_DIR` | bin directory (default `$PREFIX/bin`) |
| `CODEX_DUAL_ENGINE_LITE_SKILLS_DIR` | skills directory (default `$CODEX_HOME/skills`) |
| `CODEX_DUAL_ENGINE_LITE_AGENTS_DIR` | agents directory (default `$CODEX_HOME/agents`) |
| `CODEX_HOME` | Codex home (default `$HOME/.codex`) |

The installer is idempotent. If a destination already exists and differs, it
fails safely; pass `--force` to back the existing file up to a `.bak.*` file
first. `install.sh --install-agent` additionally installs the optional
`agents/openai.yaml` reference (off by default because custom agent support
varies by Codex CLI version).

## Keychain setup

The worker reads the API key from a generic Keychain item. Service and account
names are identifiers, not secrets, and both are configurable. With the
defaults, add the key once (the value is never written to disk by this tool):

```sh
security add-generic-password \
  -a "deepseek-api-key" \
  -s "codex-dual-engine-lite" \
  -w "YOUR_API_KEY"
```

Use a different service/account by editing `config/config.example.toml` (or the
`keychain.service` and `keychain.account` keys in your config), or override
`CODEX_DUAL_ENGINE_LITE_KEYCHAIN_SERVICE` and
`CODEX_DUAL_ENGINE_LITE_KEYCHAIN_ACCOUNT`.

`bin/codex-ds` removes any inherited `DEEPSEEK_API_KEY` from the child
environment and injects only the Keychain value for the model process. It never
places the key in argv, stdout, logs, or generated configuration.

## Configuration

Copy the example and edit it:

```sh
mkdir -p "$HOME/.local/share/codex-dual-engine-lite"
cp config/config.example.toml "$HOME/.local/share/codex-dual-engine-lite/config.toml"
```

```toml
[provider]
name = "deepseek"
base_url = "REPLACE_WITH_BASE_URL"
model = "REPLACE_WITH_MODEL"
env_key = "DEEPSEEK_API_KEY"

[keychain]
service = "codex-dual-engine-lite"
account = "deepseek-api-key"

[execution]
sandbox = "workspace-write"   # read-only or workspace-write; danger-full-access is rejected
auto_approve = false          # explicit opt-in; maps to --approve-for-me

[preflight]
allowlist = ""                # optional comma-separated repo-relative globs
```

All of these values can also be supplied via environment variables
(`CODEX_DUAL_ENGINE_LITE_PROVIDER`, `..._MODEL`, `..._BASE_URL`,
`..._ENV_KEY`, `..._SANDBOX`, `..._AUTO_APPROVE`). Configuration values are
validated; `danger-full-access` and the approval/sandbox bypass flag are never
emitted.

## Manual workflow

1. Make sure you are inside a clean Git repository with a HEAD commit:

   ```sh
   cd /path/to/your/repository
   git status --porcelain   # must be empty
   ```

2. Run one bounded task:

   ```sh
   deepseek-worker "implement the requested change"
   # or: deepseek-worker --task-file task.txt
   # or: printf '%s' "..." | deepseek-worker -
   ```

   The worker prints the task id on stdout and writes the result package under
   `$CODEX_DUAL_ENGINE_LITE_HOME/tasks/<task-id>/result/`.

3. Inspect the result package (see below).

4. Record the independent human/Sol verdict:

   ```sh
   deepseek-worker-review TASK_ID PASS|RETRY|TAKEOVER "optional note"
   ```

   - `PASS`: acceptable to apply manually.
   - `RETRY`: re-run with a refined task.
   - `TAKEOVER`: a human takes over.

   `PASS` is fail-closed; see the PASS gate section below.

5. Clean up the managed worktree and branch (results are preserved):

   ```sh
   deepseek-worker-clean TASK_ID --yes
   ```

## Result package

For a task id, the result directory contains:

| file | purpose |
| --- | --- |
| `TASK_RESULT.md` | summary, including model exit status and whether files changed |
| `changed-files.txt` | repository-relative changed/new paths |
| `diff.patch` | complete untrusted patch against HEAD: tracked, staged, deleted, renamed, and untracked new files (including binary content) |
| `metadata.json` | non-secret operational facts |
| `REVIEW_PACKET.json` | compact, locally computed review index and budget state |
| `worker.log` | full worker and model log (mode 0600) |
| `task.txt` | the original task text (mode 0600) |
| `SOL_REVIEW.md` | review verdict, once recorded |

The model exit status and the "files changed" flag are recorded separately; a
failed model run can still produce (or not produce) file changes, and both
facts are preserved.

### PASS gate

`deepseek-worker-review TASK_ID PASS ...` refuses to record `PASS` (and does
not create or modify `SOL_REVIEW.md`) unless all of the following hold:

- `REVIEW_PACKET.json`, `metadata.json`, `diff.patch`, `changed-files.txt`,
  `task.txt`, and `TASK_RESULT.md` exist as regular, non-symlink files in the
  validated managed result directory.
- `REVIEW_PACKET.json` is valid and its schema is `dual-engine-review.v1`.
- `model_exit_status` is exactly `0`.
- `budget.exceeded` is `false`.
- `main_worktree_clean_after` is `true`.
- the current SHA-256 of `diff.patch` matches `patch_sha256`.
- the current nonblank line count of `changed-files.txt` matches
  `changed_file_count`.
- the source repository recorded in the managed marker still exists, is a Git
  worktree, and is currently clean.

Missing, malformed, duplicate, or ambiguous required JSON fields fail closed.
The recorder checks these local invariants; it does not reason about whether
the code change is correct or safe to apply. `RETRY` and `TAKEOVER` remain
recordable for failed or incomplete tasks.

## Secret preflight

Before the model runs, the worker scans tracked files in the isolated worktree
(never `.git` internals or generated task-data directories). It is fail-closed:
any block stops the run before the model command.

High-risk filenames include private key names (`id_rsa`, `*.pem`, `*.key`),
`.env*`, `.netrc`, `.npmrc`, `.pypirc`, `.pgpass`, and common credential/secret
file names. High-confidence content rules cover PEM/PGP private key blocks,
AWS `AKIA...` access key ids, GitHub tokens, Google API keys, `sk-...` API
keys, Slack tokens, and npm access tokens.

Diagnostics show only the repository-relative filename and rule name; they
never echo matching values or full matching lines. A narrowly scoped allowlist
is available via `[preflight] allowlist` (comma-separated globs matched against
repository-relative paths and basenames). PEM and PGP private-key block markers
are assembled at runtime so the shipped worker does not contain the literal
signatures that this same preflight must block.

## Doctor

Run read-only diagnostics at any time:

```sh
deepseek-worker-doctor
```

It checks the platform, required commands, Codex CLI presence/version,
configuration and directory permissions, Keychain item availability (presence
only, never the secret), and repository readiness.

## Uninstall

```sh
uninstall.sh
```

Uninstall removes only the exact files recorded in the install manifest
(verified by content hash) and preserves user configuration and task data.
Run it with the same prefix/environment used at install time.

## Security

See [SECURITY.md](SECURITY.md) and [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md).
The threat model explicitly covers prompt injection from repository content,
secret exposure, malicious paths/symlinks, command/task injection, log leakage,
over-broad sandbox/approval settings, untrusted patches, and the independent
human/Sol review boundary.

The most important operational rules are:

- keep the data directory private (`chmod 700`);
- treat `diff.patch` and model output as untrusted;
- review every result independently before applying anything.

## Tests

The suite is fully offline and uses a temporary `HOME`, data/config directory,
repositories, and a stub `codex-ds`:

```sh
bash tests/run_tests.sh
```

It covers script syntax, a successful isolated run, secret filename/content
preflight (including runtime-generated PEM and PGP private-key markers and a
shipped-tree self-scan with no allowlist), placeholder non-blocking,
dirty-repository rejection, model exit-vs-changes distinction, review
validation and traversal defense, cleanup validation and result preservation,
fail-closed PASS-gate coverage (positive and negative cases), complete
`diff.patch` capture for tracked and untracked (including binary) files, and
safe install/uninstall.

## Known limitations

- macOS only (v0.2); no Windows/Linux hardening.
- The bundled TOML parser is minimal: full-line comments only, no inline
  comments or arrays.
- `diff.patch` is a complete Git patch for tracked, staged, deleted, renamed,
  and untracked new files (including binary content), but remains untrusted
  model output. One edge case: an untracked symlink that points to a directory
  is listed in `changed-files.txt` but is not embedded in the patch.
- The worker cannot read an exact provider token counter in real time. Runtime
  and private-log budgets therefore act as circuit breakers, while exact token
  usage belongs in external A/B telemetry when available.
- A same-user local process can generally observe this user's files and
  Keychain; the tool defends against path injection and operator error, not
  against an already-compromised account.

## Cost control and Harness experiment

See [docs/COST_CONTROL_AND_AB.md](docs/COST_CONTROL_AND_AB.md) for the quiet
delegation protocol, fixed review packet, risk-based Sol review, budgets, and
the controlled Codex CLI versus DeepSeek Harness experiment.

## Not implemented

By design this repository does **not** include automatic task routing, a retry
manager, automatic merging, a production DeepSeek Harness integration, Claude
Code integration, Luna integration, a GUI, GitHub Actions, telemetry, package
publishing, or remote publishing. A bounded local Harness A/B is documented as
an experiment, not a migration.
