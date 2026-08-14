#!/usr/bin/env bash
# Codex Dual Engine Lite - offline automated test suite (macOS v0.2.0)
#
# Runs entirely offline using a temporary HOME, data/config directory, and a
# stub codex-ds. It never invokes a real model and never touches real state.

set -u
shopt -s extglob 2>/dev/null || true

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/cde-lite-tests.XXXXXX") || {
  printf 'fatal: could not create temporary directory\n' >&2
  exit 1
}

trap 'rm -rf -- "$TEST_TMP"' EXIT

PASS=0
FAIL=0
FAILED_NAMES=()

ok() { PASS=$((PASS + 1)); printf 'ok %d - %s\n' "$PASS" "$*"; }
not_ok() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$*"); printf 'not ok - %s\n' "$*"; }

assert() {
  local desc="$1"; shift
  if "$@"; then ok "$desc"; else not_ok "$desc"; fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then ok "$desc"; else not_ok "$desc (expected [$expected], got [$actual])"; fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then ok "$desc"; else not_ok "$desc (missing [$needle])"; fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then not_ok "$desc (found [$needle])"; else ok "$desc"; fi
}

perm_octal() { stat -f '%Lp' "$1" 2>/dev/null || printf 'n/a\n'; }

# --- shared environment ---------------------------------------------------

TEST_HOME="$TEST_TMP/home"
TEST_DATA="$TEST_HOME/.local/share/codex-dual-engine-lite"
TEST_CONFIG="$TEST_DATA/config.toml"
STUB="$TEST_TMP/stub-codex-ds"
STUB_LOG="$TEST_TMP/stub-codex-ds.log"

mkdir -p "$TEST_HOME" "$TEST_DATA"

# Minimal valid config for worker-driven tests (the stub ignores model calls).
cat > "$TEST_CONFIG" <<'EOF'
[provider]
name = "deepseek"
base_url = "https://example.invalid/v1"
model = "deepseek-chat"
env_key = "DEEPSEEK_API_KEY"

[keychain]
service = "codex-dual-engine-lite"
account = "deepseek-api-key"

[execution]
sandbox = "workspace-write"
auto_approve = false

[preflight]
allowlist = ""

[budgets]
max_runtime_seconds = 1800
max_log_bytes = 2000000
max_changed_files = 100
max_patch_bytes = 5000000
EOF

cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
set -u
log="${CDE_STUB_LOG:-/dev/null}"
task=$(cat)
{
  printf 'STUB_INVOKED\n'
  printf 'argv=%s\n' "$*"
  printf 'task_len=%s\n' "${#task}"
  printf 'cwd=%s\n' "$(pwd -P)"
  printf 'task_id=%s\n' "${CODEX_DUAL_ENGINE_LITE_TASK_ID:-<unset>}"
} >> "$log"
if [[ -z "${CDE_STUB_NOCHANGE:-}" ]]; then
  printf 'stub new file\n' > stub-new-file.txt
  printf 'STUB CHANGE\n' >> src/hello.txt
  if [[ -n "${CDE_STUB_BINARY:-}" ]]; then
    printf 'BIN\000\001\002STUFF\377\n' > stub-new-binary.bin
  fi
fi
if [[ -n "${CDE_STUB_OUTPUT_BYTES:-}" ]]; then
  written=0
  chunk='XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX'
  while ((written < CDE_STUB_OUTPUT_BYTES)); do
    printf '%s\n' "$chunk"
    written=$((written + ${#chunk} + 1))
  done
fi
if [[ -n "${CDE_STUB_SLEEP_SECONDS:-}" ]]; then
  sleep "$CDE_STUB_SLEEP_SECONDS"
fi
exit "${CDE_STUB_EXIT:-0}"
EOF
chmod 700 "$STUB"

new_repo() {
  local name="$1"
  local repo="$TEST_TMP/repos/$name"
  case "$repo" in
    "$TEST_TMP"/*) ;;
    *) printf 'fatal: unsafe repo path\n' >&2; exit 1 ;;
  esac
  rm -rf -- "$repo"
  mkdir -p "$repo/src"
  git -C "$repo" init -q
  git -C "$repo" config user.name "CodexTest"
  git -C "$repo" config user.email "test@example.invalid"
  git -C "$repo" config commit.gpgsign false
  printf 'hello\n' > "$repo/src/hello.txt"
  printf '# Repo\n' > "$repo/README.md"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "initial"
  printf '%s\n' "$repo"
}

reset_stub() {
  : > "$STUB_LOG"
  CDE_STUB_EXIT=""
  CDE_STUB_NOCHANGE=""
  CDE_STUB_BINARY=""
  CDE_STUB_OUTPUT_BYTES=""
  CDE_STUB_SLEEP_SECONDS=""
  CDE_TEST_MAX_RUNTIME_SECONDS="1800"
  CDE_TEST_MAX_LOG_BYTES="2000000"
  CDE_TEST_MAX_CHANGED_FILES="100"
  CDE_TEST_MAX_PATCH_BYTES="5000000"
}

run_worker() {
  local repo="$1" task="$2"
  local err_file="$TEST_TMP/worker-stderr"
  WORKER_STDOUT=""
  WORKER_ERR=""
  WORKER_RC=0
  WORKER_STDOUT=$( (cd "$repo" && env \
    HOME="$TEST_HOME" \
    CODEX_DUAL_ENGINE_LITE_HOME="$TEST_DATA" \
    CODEX_DUAL_ENGINE_LITE_CONFIG="$TEST_CONFIG" \
    CODEX_DUAL_ENGINE_LITE_CODEX_DS="$STUB" \
    CDE_STUB_LOG="$STUB_LOG" \
    CDE_STUB_EXIT="${CDE_STUB_EXIT:-}" \
    CDE_STUB_NOCHANGE="${CDE_STUB_NOCHANGE:-}" \
    CDE_STUB_BINARY="${CDE_STUB_BINARY:-}" \
    CDE_STUB_OUTPUT_BYTES="${CDE_STUB_OUTPUT_BYTES:-}" \
    CDE_STUB_SLEEP_SECONDS="${CDE_STUB_SLEEP_SECONDS:-}" \
    CODEX_DUAL_ENGINE_LITE_MAX_RUNTIME_SECONDS="$CDE_TEST_MAX_RUNTIME_SECONDS" \
    CODEX_DUAL_ENGINE_LITE_MAX_LOG_BYTES="$CDE_TEST_MAX_LOG_BYTES" \
    CODEX_DUAL_ENGINE_LITE_MAX_CHANGED_FILES="$CDE_TEST_MAX_CHANGED_FILES" \
    CODEX_DUAL_ENGINE_LITE_MAX_PATCH_BYTES="$CDE_TEST_MAX_PATCH_BYTES" \
    "$REPO_ROOT/bin/deepseek-worker" "$task") 2>"$err_file" )
  WORKER_RC=$?
  WORKER_ERR=$(cat "$err_file")
}

run_review() {
  env HOME="$TEST_HOME" CODEX_DUAL_ENGINE_LITE_HOME="$TEST_DATA" \
    "$REPO_ROOT/bin/deepseek-worker-review" "$@"
}

clone_review_task() {
  local src_id="$1" dst_id="$2" src dst
  case "$dst_id" in
    *..*|*/*) printf 'fatal: unsafe review clone id\n' >&2; exit 1 ;;
  esac
  src="$TEST_DATA/tasks/$src_id"
  dst="$TEST_DATA/tasks/$dst_id"
  [[ -d "$src" && -d "$src/result" ]] || {
    printf 'fatal: missing review clone source\n' >&2
    exit 1
  }
  mkdir -p "$dst"
  sed "s/^task_id=.*/task_id=$dst_id/" "$src/.managed" > "$dst/.managed"
  cp -R "$src/result" "$dst/result"
}

set_top_level_number() {
  local packet="$1" key="$2" value="$3" out="$TEST_TMP/review-packet.mut"
  awk -v key="$key" -v value="$value" '
    {
      pattern="  \"" key "\":"
      if (index($0, pattern) == 1) {
        print "  \"" key "\": " value ","
        next
      }
      print
    }
  ' "$packet" > "$out"
  mv "$out" "$packet"
}

set_budget_exceeded_true() {
  local packet="$1" out="$TEST_TMP/review-packet.mut"
  awk '
    /"exceeded":/ {
      print "    \"exceeded\": true,"
      next
    }
    { print }
  ' "$packet" > "$out"
  mv "$out" "$packet"
}

duplicate_schema_packet() {
  local packet="$1" out="$TEST_TMP/review-packet.mut"
  awk '
    /^  "reviewer_validation":/ {
      print "  \"reviewer_validation\": \"NOT_RUN_BY_REVIEWER\","
      next
    }
    /^}/ {
      print "  \"schema\": \"dual-engine-review.v1\""
      print
      next
    }
    { print }
  ' "$packet" > "$out"
  mv "$out" "$packet"
}

run_clean() {
  env HOME="$TEST_HOME" CODEX_DUAL_ENGINE_LITE_HOME="$TEST_DATA" \
    "$REPO_ROOT/bin/deepseek-worker-clean" "$@"
}

# --- 1. syntax ------------------------------------------------------------

test_syntax() {
  local f rc=0
  for f in "$REPO_ROOT"/bin/* "$REPO_ROOT"/install.sh "$REPO_ROOT"/uninstall.sh; do
    bash -n "$f" 2>"$TEST_TMP/bashn.err" || { rc=1; break; }
  done
  assert_eq "all shipped scripts pass 'bash -n'" 0 "$rc"
}

# --- 2. successful worker run --------------------------------------------

test_successful_run() {
  local repo
  repo=$(new_repo success)
  local head_before log_before
  head_before=$(git -C "$repo" rev-parse HEAD)
  log_before=$(git -C "$repo" log --oneline | wc -l | tr -d ' ')
  reset_stub
  CDE_STUB_BINARY=1

  run_worker "$repo" "write a change to the repo"
  assert_eq "worker exits 0 on successful run" 0 "$WORKER_RC"

  local task_id="$WORKER_STDOUT"
  assert "worker prints a task id" test -n "$task_id"

  local result_dir="$TEST_DATA/tasks/$task_id/result"
  assert "result directory exists" test -d "$result_dir"
  assert "TASK_RESULT.md exists" test -f "$result_dir/TASK_RESULT.md"
  assert "changed-files.txt exists" test -f "$result_dir/changed-files.txt"
  assert "diff.patch exists" test -f "$result_dir/diff.patch"
  assert "metadata.json exists" test -f "$result_dir/metadata.json"
  assert "REVIEW_PACKET.json exists" test -f "$result_dir/REVIEW_PACKET.json"
  assert "worker.log exists" test -f "$result_dir/worker.log"
  assert "task.txt exists" test -f "$result_dir/task.txt"

  assert_contains "changed-files lists tracked change" "$(cat "$result_dir/changed-files.txt")" "src/hello.txt"
  assert_contains "changed-files lists untracked new file" "$(cat "$result_dir/changed-files.txt")" "stub-new-file.txt"
  assert_contains "changed-files lists untracked binary file" "$(cat "$result_dir/changed-files.txt")" "stub-new-binary.bin"
  assert_contains "diff.patch contains model change" "$(cat "$result_dir/diff.patch")" "STUB CHANGE"
  assert_contains "diff.patch contains untracked new file content" "$(cat "$result_dir/diff.patch")" "stub new file"
  assert_contains "diff.patch records untracked new file path" "$(cat "$result_dir/diff.patch")" "stub-new-file.txt"
  assert_contains "diff.patch records untracked binary file path" "$(cat "$result_dir/diff.patch")" "stub-new-binary.bin"
  assert_contains "diff.patch embeds binary content as Git binary patch" "$(cat "$result_dir/diff.patch")" "GIT binary patch"
  assert_contains "TASK_RESULT describes complete untrusted patch" "$(cat "$result_dir/TASK_RESULT.md")" "complete untrusted patch"
  assert_contains "metadata records model exit 0" "$(cat "$result_dir/metadata.json")" '"model_exit_status": 0'
  assert_contains "metadata records files changed true" "$(cat "$result_dir/metadata.json")" '"files_changed": true'
  assert_contains "review packet uses v1 schema" "$(cat "$result_dir/REVIEW_PACKET.json")" '"schema": "dual-engine-review.v1"'
  assert_contains "review packet records no budget breach" "$(cat "$result_dir/REVIEW_PACKET.json")" '"exceeded": false'
  assert_contains "review packet assigns conservative risk" "$(cat "$result_dir/REVIEW_PACKET.json")" '"level": "YELLOW"'
  assert_contains "review packet requires reviewer validation" "$(cat "$result_dir/REVIEW_PACKET.json")" '"reviewer_validation": "NOT_RUN_BY_REVIEWER"'
  local expected_patch_sha
  expected_patch_sha=$(shasum -a 256 "$result_dir/diff.patch" | awk '{print $1}')
  assert_contains "review packet patch hash matches artifact" "$(cat "$result_dir/REVIEW_PACKET.json")" "$expected_patch_sha"
  assert_contains "stub was invoked" "$(cat "$STUB_LOG" 2>/dev/null)" "STUB_INVOKED"

  assert_eq "worker.log is mode 0600" 600 "$(perm_octal "$result_dir/worker.log")"
  assert_eq "review packet is mode 0600" 600 "$(perm_octal "$result_dir/REVIEW_PACKET.json")"
  assert_eq "result dir is mode 0700" 700 "$(perm_octal "$result_dir")"
  assert_eq "delegated worktree has no staged changes after patch generation" "" "$(git -C "$TEST_DATA/tasks/$task_id/worktree" diff --cached --name-only 2>/dev/null)"

  local head_after log_after status_after hello_after
  head_after=$(git -C "$repo" rev-parse HEAD)
  log_after=$(git -C "$repo" log --oneline | wc -l | tr -d ' ')
  status_after=$(git -C "$repo" status --porcelain)
  hello_after=$(cat "$repo/src/hello.txt")

  assert_eq "main worktree HEAD unchanged" "$head_before" "$head_after"
  assert_eq "no commit was created" "$log_before" "$log_after"
  assert_eq "main worktree is clean" "" "$status_after"
  assert_eq "main worktree file content unchanged" "hello" "$hello_after"

  assert_contains "managed branch exists" "$(git -C "$repo" branch --list)" "codex-ds/$task_id"
  local wt_canon
  wt_canon=$(cd -P "$TEST_DATA/tasks/$task_id/worktree" && pwd -P)
  assert_contains "worktree is registered" "$(git -C "$repo" worktree list --porcelain)" "worktree $wt_canon"
}

# --- 3. live budget stop -------------------------------------------------

test_log_budget_stop() {
  local repo
  repo=$(new_repo log-budget)
  reset_stub
  CDE_STUB_OUTPUT_BYTES=8192
  CDE_STUB_SLEEP_SECONDS=10
  CDE_TEST_MAX_LOG_BYTES=1024

  run_worker "$repo" "produce enough output to trigger the log budget"
  assert_eq "budget-stopped worker still returns a reviewable task id" 0 "$WORKER_RC"

  local task_id="$WORKER_STDOUT"
  local result_dir="$TEST_DATA/tasks/$task_id/result"
  assert "budget stop still writes review packet" test -f "$result_dir/REVIEW_PACKET.json"
  assert_contains "review packet records budget breach" "$(cat "$result_dir/REVIEW_PACKET.json")" '"exceeded": true'
  assert_contains "review packet records log stop reason" "$(cat "$result_dir/REVIEW_PACKET.json")" 'log_size_limit_exceeded'
  assert_not_contains "budget-stopped model cannot report exit zero" "$(cat "$result_dir/REVIEW_PACKET.json")" '"model_exit_status": 0'
  assert_contains "private log records enforced stop" "$(cat "$result_dir/worker.log")" 'budget stop: log_size_limit_exceeded'
}

# --- 4. secret filename preflight ----------------------------------------

test_secret_filename() {
  local repo
  repo=$(new_repo secret-filename)
  printf 'DEEPSEEK_API_KEY=sk-SUPER-SECRET-VALUE-1234567890abcdef\n' > "$repo/.env"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "add env file"
  reset_stub

  run_worker "$repo" "please do something"
  assert_eq "secret filename preflight blocks before model" 4 "$WORKER_RC"

  local combined="$WORKER_STDOUT
$WORKER_ERR"
  assert_contains "diagnostics name the blocked file" "$combined" ".env"
  assert_contains "diagnostics name a filename rule" "$combined" "filename:"
  assert_not_contains "diagnostics do not leak secret value" "$combined" "sk-SUPER-SECRET-VALUE"
  assert_eq "stub model was not invoked" "" "$(cat "$STUB_LOG" 2>/dev/null)"
}

# --- 4. secret content preflight -----------------------------------------

test_secret_content() {
  local repo
  repo=$(new_repo secret-content)
  mkdir -p "$repo/docs"
  local secret_body="MIIEpQIBAAKCAQEA0123456789abcdef0123456789abcdefSECRETKEYBODY"
  {
    printf '%s\n' '-----BEGIN RSA PRIVATE KEY-----'
    printf '%s\n' "$secret_body"
    printf '%s\n' '-----END RSA PRIVATE KEY-----'
  } > "$repo/docs/notes.txt"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "add private key in docs"
  reset_stub

  run_worker "$repo" "please do something"
  assert_eq "secret content preflight blocks before model" 4 "$WORKER_RC"

  local combined="$WORKER_STDOUT
$WORKER_ERR"
  assert_contains "diagnostics name the blocked file" "$combined" "docs/notes.txt"
  assert_contains "diagnostics name the content rule" "$combined" "content:pem-private-key"
  assert_not_contains "diagnostics do not leak the key body" "$combined" "$secret_body"
  assert_eq "stub model was not invoked" "" "$(cat "$STUB_LOG" 2>/dev/null)"
}

# --- 5. placeholders are not falsely blocked -----------------------------

test_placeholders_not_blocked() {
  local repo
  repo=$(new_repo placeholders)
  cat > "$repo/config.example.toml" <<'EOF'
api_key = "REPLACE_WITH_API_KEY"
password = "changeme"
token = "YOUR_TOKEN_HERE"
EOF
  printf 'EXAMPLE_ONLY=true\n' > "$repo/example.env"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "add example placeholders"
  reset_stub

  run_worker "$repo" "make an example change"
  assert_eq "placeholder configuration is not falsely blocked" 0 "$WORKER_RC"
  assert_contains "stub model was invoked" "$(cat "$STUB_LOG" 2>/dev/null)" "STUB_INVOKED"
}

# --- 6. dirty repositories are rejected ----------------------------------

test_dirty_repo_rejected() {
  local repo
  repo=$(new_repo dirty)
  printf 'uncommitted\n' >> "$repo/src/hello.txt"
  reset_stub
  local before
  before=$(ls -A "$TEST_DATA/tasks" 2>/dev/null | sort | tr '\n' ' ')

  run_worker "$repo" "do work"
  assert_eq "dirty repository is rejected" 3 "$WORKER_RC"
  assert_eq "stub model was not invoked" "" "$(cat "$STUB_LOG" 2>/dev/null)"
  local after
  after=$(ls -A "$TEST_DATA/tasks" 2>/dev/null | sort | tr '\n' ' ')
  assert_eq "dirty repo creates no new task directory" "$before" "$after"
}

# --- model exit status vs files-changed distinction -----------------------

test_model_failure_distinguished() {
  local repo
  repo=$(new_repo model-failure)
  reset_stub
  CDE_STUB_EXIT=7
  CDE_STUB_NOCHANGE=1

  run_worker "$repo" "do work that the model fails to complete"
  assert_eq "worker still completes when model fails" 0 "$WORKER_RC"
  local task_id="$WORKER_STDOUT"
  local result_dir="$TEST_DATA/tasks/$task_id/result"
  assert_contains "metadata records model exit 7" "$(cat "$result_dir/metadata.json")" '"model_exit_status": 7'
  assert_contains "metadata records files changed false" "$(cat "$result_dir/metadata.json")" '"files_changed": false'
  assert_contains "TASK_RESULT distinguishes model exit status" "$(cat "$result_dir/TASK_RESULT.md")" "model exit status | 7"
  assert_contains "TASK_RESULT distinguishes files changed" "$(cat "$result_dir/TASK_RESULT.md")" "files changed | false (0 files)"
}

# --- 7. review validation and traversal defense --------------------------

test_review() {
  local repo
  repo=$(new_repo review)
  reset_stub
  run_worker "$repo" "do work for review"
  assert_eq "worker run for review succeeds" 0 "$WORKER_RC"
  local task_id="$WORKER_STDOUT"
  local result_dir="$TEST_DATA/tasks/$task_id/result"

  run_review "$task_id" MAYBE >/dev/null 2>&1
  assert_eq "invalid verdict is rejected" 2 "$?"
  assert "SOL_REVIEW.md not written for invalid verdict" test ! -f "$result_dir/SOL_REVIEW.md"

  run_review "../evil" PASS >/dev/null 2>&1
  assert_eq "traversal task id is rejected" 2 "$?"

  run_review "foo/bar" PASS >/dev/null 2>&1
  assert_eq "path-separator task id is rejected" 2 "$?"

  # Symlink escape defense: a fake managed task whose result dir is a symlink.
  local evil="$TEST_DATA/tasks/evil"
  mkdir -p "$evil" "$TEST_TMP/outside-dir"
  printf 'task_id=evil\n' > "$evil/.managed"
  ln -s "$TEST_TMP/outside-dir" "$evil/result"
  run_review evil PASS >/dev/null 2>&1
  assert_eq "symlinked result dir is rejected" 1 "$?"
  assert "no review written outside the data dir" test ! -f "$TEST_TMP/outside-dir/SOL_REVIEW.md"

  run_review "$task_id" PASS "looks good" >/dev/null 2>&1
  assert_eq "valid PASS verdict is recorded" 0 "$?"
  assert "SOL_REVIEW.md exists" test -f "$result_dir/SOL_REVIEW.md"
  assert_contains "review records verdict" "$(cat "$result_dir/SOL_REVIEW.md")" "verdict: PASS"
  assert_contains "review records note" "$(cat "$result_dir/SOL_REVIEW.md")" "looks good"
  assert_eq "review file is mode 0600" 600 "$(perm_octal "$result_dir/SOL_REVIEW.md")"

  local head_before head_after
  head_before=$(git -C "$repo" rev-parse HEAD)
  run_review "$task_id" TAKEOVER >/dev/null 2>&1
  head_after=$(git -C "$repo" rev-parse HEAD)
  assert_eq "review does not merge or change HEAD" "$head_before" "$head_after"
}

# --- 7b. fail-closed PASS gate -------------------------------------------

test_review_pass_gate() {
  local repo
  repo=$(new_repo pass-gate)
  reset_stub
  run_worker "$repo" "do work for pass gate"
  assert_eq "worker run for pass gate succeeds" 0 "$WORKER_RC"
  local base_task="$WORKER_STDOUT"

  local id result_dir

  id="pass-positive"
  clone_review_task "$base_task" "$id"
  result_dir="$TEST_DATA/tasks/$id/result"
  run_review "$id" PASS "positive" >/dev/null 2>&1
  assert_eq "PASS succeeds for internally consistent package" 0 "$?"
  assert "positive PASS writes SOL_REVIEW.md" test -f "$result_dir/SOL_REVIEW.md"
  assert_contains "positive PASS records verdict" "$(cat "$result_dir/SOL_REVIEW.md")" "verdict: PASS"

  id="pass-nonzero-status"
  clone_review_task "$base_task" "$id"
  result_dir="$TEST_DATA/tasks/$id/result"
  set_top_level_number "$result_dir/REVIEW_PACKET.json" "model_exit_status" 7
  run_review "$id" PASS >/dev/null 2>&1
  assert_eq "nonzero model_exit_status blocks PASS" 1 "$?"
  assert "nonzero PASS writes no SOL_REVIEW.md" test ! -f "$result_dir/SOL_REVIEW.md"
  run_review "$id" RETRY >/dev/null 2>&1
  assert_eq "RETRY records for failed task" 0 "$?"
  assert_contains "RETRY records verdict" "$(cat "$result_dir/SOL_REVIEW.md")" "verdict: RETRY"
  run_review "$id" TAKEOVER >/dev/null 2>&1
  assert_eq "TAKEOVER records for failed task" 0 "$?"
  assert_contains "TAKEOVER records verdict" "$(cat "$result_dir/SOL_REVIEW.md")" "verdict: TAKEOVER"

  id="pass-budget-exceeded"
  clone_review_task "$base_task" "$id"
  result_dir="$TEST_DATA/tasks/$id/result"
  set_budget_exceeded_true "$result_dir/REVIEW_PACKET.json"
  run_review "$id" PASS >/dev/null 2>&1
  assert_eq "budget_exceeded true blocks PASS" 1 "$?"
  assert "budget-exceeded PASS writes no SOL_REVIEW.md" test ! -f "$result_dir/SOL_REVIEW.md"

  id="pass-bad-sha"
  clone_review_task "$base_task" "$id"
  result_dir="$TEST_DATA/tasks/$id/result"
  printf 'tampered patch\n' >> "$result_dir/diff.patch"
  run_review "$id" PASS >/dev/null 2>&1
  assert_eq "tampered diff.patch hash blocks PASS" 1 "$?"
  assert "tampered-hash PASS writes no SOL_REVIEW.md" test ! -f "$result_dir/SOL_REVIEW.md"

  id="pass-bad-count"
  clone_review_task "$base_task" "$id"
  result_dir="$TEST_DATA/tasks/$id/result"
  set_top_level_number "$result_dir/REVIEW_PACKET.json" "changed_file_count" 999
  run_review "$id" PASS >/dev/null 2>&1
  assert_eq "mismatched changed_file_count blocks PASS" 1 "$?"
  assert "mismatched-count PASS writes no SOL_REVIEW.md" test ! -f "$result_dir/SOL_REVIEW.md"

  id="pass-missing-packet"
  clone_review_task "$base_task" "$id"
  result_dir="$TEST_DATA/tasks/$id/result"
  mv "$result_dir/REVIEW_PACKET.json" "$TEST_TMP/pass-missing-packet.json"
  run_review "$id" PASS >/dev/null 2>&1
  assert_eq "missing REVIEW_PACKET.json blocks PASS" 1 "$?"
  assert "missing-packet PASS writes no SOL_REVIEW.md" test ! -f "$result_dir/SOL_REVIEW.md"

  id="pass-malformed"
  clone_review_task "$base_task" "$id"
  result_dir="$TEST_DATA/tasks/$id/result"
  printf '%s\n' '{"schema":"dual-engine-review.v1","model_exit_status":0,}' > "$result_dir/REVIEW_PACKET.json"
  run_review "$id" PASS >/dev/null 2>&1
  assert_eq "malformed review packet blocks PASS" 1 "$?"
  assert "malformed-packet PASS writes no SOL_REVIEW.md" test ! -f "$result_dir/SOL_REVIEW.md"

  id="pass-duplicate"
  clone_review_task "$base_task" "$id"
  result_dir="$TEST_DATA/tasks/$id/result"
  duplicate_schema_packet "$result_dir/REVIEW_PACKET.json"
  run_review "$id" PASS >/dev/null 2>&1
  assert_eq "duplicate required field blocks PASS" 1 "$?"
  assert "duplicate-field PASS writes no SOL_REVIEW.md" test ! -f "$result_dir/SOL_REVIEW.md"

  id="pass-symlink-artifact"
  clone_review_task "$base_task" "$id"
  result_dir="$TEST_DATA/tasks/$id/result"
  mv "$result_dir/task.txt" "$TEST_TMP/pass-real-task.txt"
  ln -s "$TEST_TMP/pass-real-task.txt" "$result_dir/task.txt"
  run_review "$id" PASS >/dev/null 2>&1
  assert_eq "symlinked required artifact blocks PASS" 1 "$?"
  assert "symlink-artifact PASS writes no SOL_REVIEW.md" test ! -f "$result_dir/SOL_REVIEW.md"

  local dirty_repo dirty_task dirty_result
  dirty_repo=$(new_repo pass-dirty)
  reset_stub
  run_worker "$dirty_repo" "do work then dirty main repo"
  assert_eq "worker run for dirty PASS case succeeds" 0 "$WORKER_RC"
  dirty_task="$WORKER_STDOUT"
  dirty_result="$TEST_DATA/tasks/$dirty_task/result"
  printf 'uncommitted after review package\n' >> "$dirty_repo/src/hello.txt"
  run_review "$dirty_task" PASS >/dev/null 2>&1
  assert_eq "dirty source repository blocks PASS" 1 "$?"
  assert "dirty-repo PASS writes no SOL_REVIEW.md" test ! -f "$dirty_result/SOL_REVIEW.md"
}

# --- 8. cleanup validation and preservation ------------------------------

test_clean() {
  local repo
  repo=$(new_repo clean)
  reset_stub
  run_worker "$repo" "do work to clean up"
  assert_eq "worker run for clean succeeds" 0 "$WORKER_RC"
  local task_id="$WORKER_STDOUT"
  local worktree="$TEST_DATA/tasks/$task_id/worktree"
  local result_dir="$TEST_DATA/tasks/$task_id/result"
  local head_before
  head_before=$(git -C "$repo" rev-parse HEAD)

  printf 'n\n' | run_clean "$task_id" >/dev/null 2>&1
  assert_eq "clean aborts without confirmation" 0 "$?"
  assert "worktree remains after abort" test -d "$worktree"

  run_clean "../evil" --yes >/dev/null 2>&1
  assert_eq "clean rejects traversal task id" 2 "$?"

  run_clean "$task_id" --yes >/dev/null 2>&1
  assert_eq "clean succeeds with --yes" 0 "$?"
  assert "worktree is removed" test ! -e "$worktree"
  assert_not_contains "branch is removed" "$(git -C "$repo" branch --list)" "codex-ds/$task_id"
  assert_not_contains "worktree no longer registered" "$(git -C "$repo" worktree list --porcelain)" "worktree $worktree"
  assert "result package is preserved" test -f "$result_dir/TASK_RESULT.md"
  assert "worker log is preserved" test -f "$result_dir/worker.log"
  assert_eq "main worktree HEAD unchanged" "$head_before" "$(git -C "$repo" rev-parse HEAD)"
}

# --- 9. safe install / uninstall ----------------------------------------

test_install_uninstall() {
  local prefix="$TEST_TMP/prefix"
  local ihome="$TEST_TMP/ihome"
  local icodex="$ihome/.codex"
  local idata="$ihome/.local/share/codex-dual-engine-lite"
  local bin_dir="$prefix/bin"
  local envs=(HOME="$ihome" CODEX_HOME="$icodex" CODEX_DUAL_ENGINE_LITE_HOME="$idata")

  env "${envs[@]}" "$REPO_ROOT/install.sh" --prefix "$prefix" --install-agent >/dev/null 2>&1
  assert_eq "install succeeds" 0 "$?"
  assert "bin script installed and executable" test -x "$bin_dir/deepseek-worker"
  assert "skill installed" test -f "$icodex/skills/deepseek-delegation/SKILL.md"
  assert "agent installed" test -f "$icodex/agents/openai.yaml"
  assert "example config created" test -f "$idata/config.toml"
  assert_eq "example config mode 0600" 600 "$(perm_octal "$idata/config.toml")"
  assert "install manifest written" test -f "$idata/install-manifest.tsv"

  env "${envs[@]}" "$REPO_ROOT/install.sh" --prefix "$prefix" --install-agent >/dev/null 2>&1
  assert_eq "install is idempotent" 0 "$?"

  printf 'junk\n' >> "$bin_dir/deepseek-worker"
  env "${envs[@]}" "$REPO_ROOT/install.sh" --prefix "$prefix" >/dev/null 2>&1
  assert_eq "install refuses to overwrite modified file" 1 "$?"
  assert_contains "modified file was not overwritten" "$(cat "$bin_dir/deepseek-worker")" "junk"

  env "${envs[@]}" "$REPO_ROOT/install.sh" --prefix "$prefix" --force >/dev/null 2>&1
  assert_eq "install --force succeeds" 0 "$?"
  assert_not_contains "force install restored the managed content" "$(cat "$bin_dir/deepseek-worker")" "junk"
  local bak
  bak=$(find "$bin_dir" -name 'deepseek-worker.bak.*' -print -quit 2>/dev/null)
  assert "backup file created" test -n "$bak"

  env "${envs[@]}" "$REPO_ROOT/uninstall.sh" --prefix "$prefix" >/dev/null 2>&1
  assert_eq "uninstall succeeds" 0 "$?"
  assert "bin script removed" test ! -e "$bin_dir/deepseek-worker"
  assert "skill removed" test ! -e "$icodex/skills/deepseek-delegation/SKILL.md"
  assert "agent removed" test ! -e "$icodex/agents/openai.yaml"
  assert "manifest removed" test ! -e "$idata/install-manifest.tsv"
  assert "user config preserved" test -f "$idata/config.toml"
}

# --- 10. codex-ds (stubbed codex + security) ------------------------------

test_codex_ds() {
  local fakebin="$TEST_TMP/fakebin"
  local codexlog="$TEST_TMP/codex.log"
  local data="$TEST_TMP/codex-ds-data"
  local cfg="$TEST_TMP/codex-ds-config.toml"
  mkdir -p "$fakebin" "$data"

  cat > "$fakebin/security" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "find-generic-password" && "${2:-}" == "-w" ]]; then
  printf '%s\n' "FAKE-KEYCHAIN-SECRET"
  exit 0
fi
exit 44
EOF
  chmod 700 "$fakebin/security"

  cat > "$fakebin/codex" <<'EOF'
#!/usr/bin/env bash
{
  printf 'argv: %s\n' "$*"
  printf 'env_key=%s\n' "${DEEPSEEK_API_KEY:-<unset>}"
  printf 'codex_home=%s\n' "${CODEX_HOME:-<unset>}"
} >> "$CDE_CODEX_LOG"
exit 0
EOF
  chmod 700 "$fakebin/codex"

  cat > "$cfg" <<'EOF'
[provider]
name = "deepseek"
base_url = "https://example.invalid/v1"
model = "deepseek-chat"
env_key = "DEEPSEEK_API_KEY"

[keychain]
service = "codex-dual-engine-lite"
account = "deepseek-api-key"

[execution]
sandbox = "workspace-write"
auto_approve = false
EOF

  : > "$codexlog"
  local out rc
  out=$(printf 'do the thing\n' | env \
    HOME="$TEST_HOME" \
    CODEX_DUAL_ENGINE_LITE_HOME="$data" \
    CODEX_DUAL_ENGINE_LITE_CONFIG="$cfg" \
    CODEX_DUAL_ENGINE_LITE_CODEX="$fakebin/codex" \
    CODEX_DUAL_ENGINE_LITE_TASK_ID="testtask" \
    DEEPSEEK_API_KEY="PARENT-LEAKED" \
    CDE_CODEX_LOG="$codexlog" \
    PATH="$fakebin:$PATH" \
    "$REPO_ROOT/bin/codex-ds" 2>&1)
  rc=$?

  assert_eq "codex-ds exits 0 with stub codex" 0 "$rc"
  assert_contains "keychain key injected into model env" "$(cat "$codexlog")" "env_key=FAKE-KEYCHAIN-SECRET"
  assert_not_contains "inherited DEEPSEEK_API_KEY is removed" "$(cat "$codexlog")" "PARENT-LEAKED"
  assert_contains "codex invoked with workspace-write sandbox" "$(cat "$codexlog")" "--sandbox workspace-write"
  assert_contains "isolated provider uses supported Responses API" "$(cat "$data/tasks/testtask/codex-home/config.toml")" 'wire_api = "responses"'
  assert_not_contains "no approval/sandbox bypass flag" "$(cat "$codexlog")" "dangerously-bypass-approvals-and-sandbox"
  assert_not_contains "keychain secret not printed by codex-ds" "$out" "FAKE-KEYCHAIN-SECRET"
  assert_not_contains "parent key not printed by codex-ds" "$out" "PARENT-LEAKED"
  assert_not_contains "isolated codex config contains no key" "$(cat "$data/tasks/testtask/codex-home/config.toml")" "FAKE-KEYCHAIN-SECRET"

  : > "$codexlog"
  out=$(printf 'x\n' | env \
    HOME="$TEST_HOME" \
    CODEX_DUAL_ENGINE_LITE_HOME="$data" \
    CODEX_DUAL_ENGINE_LITE_CONFIG="$cfg" \
    CODEX_DUAL_ENGINE_LITE_CODEX="$fakebin/codex" \
    CODEX_DUAL_ENGINE_LITE_TASK_ID="testtask2" \
    CODEX_DUAL_ENGINE_LITE_AUTO_APPROVE="true" \
    CDE_CODEX_LOG="$codexlog" \
    PATH="$fakebin:$PATH" \
    "$REPO_ROOT/bin/codex-ds" 2>&1)
  assert_eq "codex-ds opt-in run exits 0" 0 "$?"
  assert_contains "auto_approve maps to --approve-for-me" "$(cat "$codexlog")" "--approve-for-me"

  : > "$codexlog"
  out=$(printf 'x\n' | env \
    HOME="$TEST_HOME" \
    CODEX_DUAL_ENGINE_LITE_HOME="$data" \
    CODEX_DUAL_ENGINE_LITE_CONFIG="$cfg" \
    CODEX_DUAL_ENGINE_LITE_CODEX="$fakebin/codex" \
    CODEX_DUAL_ENGINE_LITE_SANDBOX="danger-full-access" \
    CDE_CODEX_LOG="$codexlog" \
    PATH="$fakebin:$PATH" \
    "$REPO_ROOT/bin/codex-ds" 2>&1)
  assert_eq "danger-full-access is rejected" 1 "$?"
  assert_eq "codex not invoked for rejected sandbox" "" "$(cat "$codexlog")"
}

# --- runner ---------------------------------------------------------------

printf 'Codex Dual Engine Lite test suite\n'
printf 'repo root: %s\n' "$REPO_ROOT"
printf 'temp dir:  %s\n\n' "$TEST_TMP"

test_syntax
test_successful_run
test_log_budget_stop
test_secret_filename
test_secret_content
test_placeholders_not_blocked
test_dirty_repo_rejected
test_model_failure_distinguished
test_review
test_review_pass_gate
test_clean
test_install_uninstall
test_codex_ds

printf '\n%d ok, %d failed\n' "$PASS" "$FAIL"
if ((${#FAILED_NAMES[@]} > 0)); then
  printf 'failures:\n'
  for name in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$name"; done
fi

exit $((FAIL > 0 ? 1 : 0))
