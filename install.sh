#!/usr/bin/env bash
# Codex Dual Engine Lite - safe, idempotent installer (macOS v0.1.0)
#
# Installs the bundled CLI scripts and the delegation skill under safe,
# configurable destinations. It never silently overwrites a modified file:
# conflicts either fail safely or are backed up with --force.

set -euo pipefail
shopt -s extglob 2>/dev/null || true

VERSION="0.1.0"
PROGRAM="install.sh"

die() { printf '%s: error: %s\n' "$PROGRAM" "$*" >&2; exit "${2:-1}"; }
info() { printf '%s: %s\n' "$PROGRAM" "$*" >&2; }

HOME="${HOME:-/tmp}"
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)

data_home() {
  local d="${CODEX_DUAL_ENGINE_LITE_HOME:-}"
  if [[ -z "$d" ]]; then
    d="$HOME/.local/share/codex-dual-engine-lite"
  fi
  printf '%s\n' "$d"
}

usage() {
  cat >&2 <<'EOF'
usage: install.sh [--prefix DIR] [--force] [--install-agent] [--help]

Install destinations (environment overrides in parentheses):
  bin scripts   $PREFIX/bin                       (CODEX_DUAL_ENGINE_LITE_BIN_DIR)
  skill         $CODEX_HOME/skills/...            (CODEX_DUAL_ENGINE_LITE_SKILLS_DIR)
  optional agent $CODEX_HOME/agents/openai.yaml    (CODEX_DUAL_ENGINE_LITE_AGENTS_DIR)
  example config $CODEX_DUAL_ENGINE_LITE_HOME/config.toml (only if absent)

options:
  --prefix DIR      base prefix (default: $HOME/.local)
  --force           back up conflicting files before overwriting
  --install-agent   also install the optional agents/openai.yaml reference
  -h, --help        show this help
EOF
  exit 0
}

prefix="${CODEX_DUAL_ENGINE_LITE_PREFIX:-$HOME/.local}"
force=0
install_agent=0

while (($# > 0)); do
  case "$1" in
    -h|--help) usage ;;
    --prefix)
      [[ $# -ge 2 ]] || die "missing value for --prefix" 2
      prefix="$2"; shift 2 ;;
    --prefix=*)
      prefix="${1#*=}"; shift ;;
    --force) force=1; shift ;;
    --install-agent) install_agent=1; shift ;;
    -*)
      die "unknown option: $1" 2 ;;
    *)
      die "unexpected argument: $1" 2 ;;
  esac
done

codex_home="${CODEX_HOME:-$HOME/.codex}"
bin_dir="${CODEX_DUAL_ENGINE_LITE_BIN_DIR:-$prefix/bin}"
skills_dir="${CODEX_DUAL_ENGINE_LITE_SKILLS_DIR:-$codex_home/skills}"
agents_dir="${CODEX_DUAL_ENGINE_LITE_AGENTS_DIR:-$codex_home/agents}"
data="$(data_home)"

[[ "$bin_dir" == /* ]] || die "bin directory must be absolute: $bin_dir" 1
[[ "$skills_dir" == /* ]] || die "skills directory must be absolute: $skills_dir" 1
[[ "$data" == /* ]] || die "data directory must be absolute: $data" 1

umask 022
mkdir -p "$data"
chmod 700 "$data" 2>/dev/null || true

manifest="$data/install-manifest.tsv"
manifest_tmp=$(mktemp "$data/.install-manifest.XXXXXX") || die "failed to create manifest temp file" 1
cleanup_tmp() { rm -f -- "$manifest_tmp"; }
trap cleanup_tmp EXIT

# Start from the previous manifest so re-running with different flags does not
# silently drop tracking of files that are still installed.
if [[ -f "$manifest" ]]; then
  cp -p "$manifest" "$manifest_tmp"
else
  : > "$manifest_tmp"
fi

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

install_one() {
  local type="$1" src="$2" dest="$3" mode="$4" src_sha dst_sha bak
  [[ -f "$src" ]] || die "source file not found: $src" 1
  src_sha=$(sha256_of "$src")

  if [[ -e "$dest" || -L "$dest" ]]; then
    if [[ -L "$dest" ]]; then
      die "refusing to overwrite symlink: $dest" 1
    fi
    if [[ -f "$dest" ]]; then
      dst_sha=$(sha256_of "$dest")
    else
      die "refusing to overwrite non-regular file: $dest" 1
    fi
    if [[ "$dst_sha" == "$src_sha" ]]; then
      info "already installed (unchanged): $dest"
      printf '%s\t%s\t%s\n' "$type" "$src_sha" "$dest" >> "$manifest_tmp"
      return 0
    fi
    if [[ "$force" == 1 ]]; then
      bak="$dest.bak.$(date +%Y%m%d%H%M%S)"
      cp -p "$dest" "$bak" || die "failed to back up $dest" 1
      info "backed up existing file to $bak"
    else
      die "refusing to overwrite modified file: $dest (re-run with --force to back it up)" 1
    fi
  fi

  mkdir -p "$(dirname "$dest")" || die "failed to create directory for $dest" 1
  if command -v install >/dev/null 2>&1; then
    install -m "$mode" "$src" "$dest" || die "failed to install $dest" 1
  else
    cp "$src" "$dest" || die "failed to install $dest" 1
    chmod "$mode" "$dest" || die "failed to set mode on $dest" 1
  fi
  printf '%s\t%s\t%s\n' "$type" "$src_sha" "$dest" >> "$manifest_tmp"
  info "installed $dest"
}

install_one bin "$REPO_ROOT/bin/codex-ds" "$bin_dir/codex-ds" 0755
install_one bin "$REPO_ROOT/bin/deepseek-worker" "$bin_dir/deepseek-worker" 0755
install_one bin "$REPO_ROOT/bin/deepseek-worker-clean" "$bin_dir/deepseek-worker-clean" 0755
install_one bin "$REPO_ROOT/bin/deepseek-worker-review" "$bin_dir/deepseek-worker-review" 0755
install_one bin "$REPO_ROOT/bin/deepseek-worker-doctor" "$bin_dir/deepseek-worker-doctor" 0755
install_one skill "$REPO_ROOT/skills/deepseek-delegation/SKILL.md" "$skills_dir/deepseek-delegation/SKILL.md" 0644

if [[ "$install_agent" == 1 ]]; then
  install_one agent "$REPO_ROOT/agents/openai.yaml" "$agents_dir/openai.yaml" 0644
fi

cfg_dest="$data/config.toml"
if [[ -e "$cfg_dest" || -L "$cfg_dest" ]]; then
  info "config already present, leaving unchanged: $cfg_dest"
else
  mkdir -p "$data"
  install -m 0600 "$REPO_ROOT/config/config.example.toml" "$cfg_dest" \
    || die "failed to create example config at $cfg_dest" 1
  info "created example config (edit it before use): $cfg_dest"
fi

chmod 600 "$manifest_tmp"
# Deduplicate by path, keeping the most recently installed entry.
manifest_dedup=$(mktemp "$data/.install-manifest.dedup.XXXXXX") || die "failed to create manifest temp file" 1
awk -F'\t' 'NF >= 3 { line[$3] = $0 } END { for (p in line) print line[p] }' "$manifest_tmp" > "$manifest_dedup"
mv -f -- "$manifest_dedup" "$manifest_tmp"
mv -f -- "$manifest_tmp" "$manifest"
trap - EXIT

info "installation complete (version $VERSION)"
info "bin directory:  $bin_dir"
info "skills directory: $skills_dir/deepseek-delegation"
if [[ "$install_agent" == 1 ]]; then
  info "agents directory: $agents_dir"
fi
info "run 'deepseek-worker-doctor' to verify the installation"
exit 0
