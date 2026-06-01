#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "FAIL: $*" >&2
  exit 1
}

note() {
  echo "==> $*" >&2
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || die "not inside a git repo"
}

cd_root() {
  cd "$(repo_root)"
}

cache_dir() {
  local root
  root="$(repo_root)"
  mkdir -p "$root/.cache/dev"
  printf '%s\n' "$root/.cache/dev"
}

timestamp() {
  date +"%Y%m%d-%H%M%S"
}

changed_files() {
  {
    git diff --name-only HEAD -- 2>/dev/null || true
    git ls-files --others --exclude-standard 2>/dev/null || true
  } | sort -u
}

redact_remote_urls() {
  sed -E 's#(https://)[^/@]+@#\1***@#g'
}
