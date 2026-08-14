#!/usr/bin/env bash
# Codex Dual Engine Lite - safe uninstaller (macOS v0.2.0)
#
# Removes only the exact files recorded in the install manifest (matching
# their content hash), and preserves user configuration and task data.

set -euo pipefail
shopt -s extglob 2>/dev/null || true

VERSION="0.2.0"
PROGRAM="uninstall.sh"

die() { printf '%s: error: %s\n' "$PROGRAM" "$*" >&2; exit "${2:-1}"; }
info() { printf '%s: %s\n' "$PROGRAM" "$*" >&2; }

HOME="${HOME:-/tmp}"

data_home() {
  local d="${CODEX_DUAL_ENGINE_LITE_HOME:-}"
  if [[ -z "$d" ]]; then
    d="$HOME/.local/share/codex-dual-engine-lite"
  fi
  printf '%s\n' "$d"
}

usage() {
  cat >&2 <<'EOF'
usage: uninstall.sh [--prefix DIR] [--help]

Removes the exact files recorded by install.sh (verified by content hash).
User configuration and task data are preserved. Run with the same
environment/prefix that was used at install time.

options:
  --prefix DIR   base prefix used at install time (default: $HOME/.local)
  -h, --help     show this help
EOF
  exit 0
}

prefix="${CODEX_DUAL_ENGINE_LITE_PREFIX:-$HOME/.local}"

while (($# > 0)); do
  case "$1" in
    -h|--help) usage ;;
    --prefix)
      [[ $# -ge 2 ]] || die "missing value for --prefix" 2
      prefix="$2"; shift 2 ;;
    --prefix=*)
      prefix="${1#*=}"; shift ;;
    *)
      die "unexpected argument: $1" 2 ;;
  esac
done

codex_home="${CODEX_HOME:-$HOME/.codex}"
bin_dir="${CODEX_DUAL_ENGINE_LITE_BIN_DIR:-$prefix/bin}"
skills_dir="${CODEX_DUAL_ENGINE_LITE_SKILLS_DIR:-$codex_home/skills}"
agents_dir="${CODEX_DUAL_ENGINE_LITE_AGENTS_DIR:-$codex_home/agents}"
data="$(data_home)"

manifest="$data/install-manifest.tsv"
[[ -f "$manifest" ]] || die "install manifest not found: $manifest (nothing to uninstall)" 1

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

removed=0
skipped=0

while IFS=$'\t' read -r type recorded_sha path; do
  [[ -n "$type" && -n "$path" ]] || continue
  case "$type" in
    bin|skill|agent) ;;
    *) die "unknown manifest entry type '$type' for $path" 1 ;;
  esac

  # Defense-in-depth: only remove paths under the expected directories.
  case "$type" in
    bin) expected_root="$bin_dir/" ;;
    skill) expected_root="$skills_dir/" ;;
    agent) expected_root="$agents_dir/" ;;
  esac
  case "$path" in
    "$expected_root"*) ;;
    *) die "manifest path escapes expected directory: $path" 1 ;;
  esac

  if [[ -L "$path" ]]; then
    info "skipping symlink (not managed by this project): $path"
    skipped=$((skipped + 1))
    continue
  fi
  if [[ ! -f "$path" ]]; then
    info "already absent: $path"
    continue
  fi

  current_sha=$(sha256_of "$path")
  if [[ "$current_sha" == "$recorded_sha" ]]; then
    rm -f -- "$path" || die "failed to remove $path" 1
    removed=$((removed + 1))
    info "removed $path"
  else
    info "skipping modified file (preserved): $path"
    skipped=$((skipped + 1))
  fi
done < "$manifest"

# Best-effort removal of now-empty directories we created.
rmdir "$skills_dir/deepseek-delegation" 2>/dev/null || true
rmdir "$skills_dir" 2>/dev/null || true
rmdir "$agents_dir" 2>/dev/null || true
rmdir "$bin_dir" 2>/dev/null || true

rm -f -- "$manifest"

info "uninstall complete: $removed removed, $skipped preserved"
info "preserved configuration and data under: $data"
exit 0
