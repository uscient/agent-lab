#!/usr/bin/env bash
# Sourced, not executed. Vets the host directory a user wants mounted at /workspace.
# The caller owns shell options (we set none here). Output follows the PASS/WARN/FAIL
# idiom used by scripts/doctor: PASS on stdout, WARN/FAIL on stderr, non-zero return on
# a hard refusal.
#
# Hard refusals are NOT overridable by design: if you truly need a sensitive dir inside
# the box, mount a scoped *copy*, never the real store.
#
# Canonicalize with `cd ... && pwd -P` (portable; resolves symlinks and `..`) rather than
# `realpath -m`, which BSD/macOS may lack.

agent_lab_guard_project_dir() {
  local raw dir home_canon t hard_hit
  raw="${1:-}"

  if [ -z "$raw" ]; then
    printf 'PASS no project dir set; using ephemeral workspace volume\n'; return 0
  fi
  if [ ! -d "$raw" ]; then
    printf 'FAIL project dir does not exist or is not a directory: %s\n' "$raw" >&2; return 1
  fi
  dir="$(cd -- "$raw" >/dev/null 2>&1 && pwd -P)" || dir=""
  if [ -z "$dir" ]; then
    printf 'FAIL cannot resolve project dir: %s\n' "$raw" >&2; return 1
  fi
  home_canon="$(cd -- "${HOME:-/nonexistent}" >/dev/null 2>&1 && pwd -P)" || home_canon=""

  # Hard refusals.
  [ "$dir" = "/" ] && { printf 'FAIL refusing to mount filesystem root\n' >&2; return 1; }
  if [ -n "$home_canon" ] && [ "$dir" = "$home_canon" ]; then
    printf 'FAIL refusing to mount your home directory: %s\n' "$dir" >&2; return 1
  fi
  if [ -n "$home_canon" ]; then
    case "$home_canon/" in
      "$dir"/*) printf 'FAIL project dir is an ancestor of HOME (%s); too broad\n' "$dir" >&2; return 1 ;;
    esac
  fi
  case "$dir" in
    /home|/Users|/root|/etc|/var|/usr|/bin|/sbin|/lib|/lib64|/opt|/boot|/sys|/proc|/dev|/mnt|/media|/srv|/run)
      printf 'FAIL refusing to mount system path: %s\n' "$dir" >&2; return 1 ;;
  esac

  hard_hit=0
  for t in .ssh .aws .gnupg .kube .git-credentials .netrc .password-store; do
    [ -e "$dir/$t" ] && { printf 'FAIL project dir contains credential material (%s): %s\n' "$t" "$dir" >&2; hard_hit=1; }
  done
  if [ -e "$dir/.npmrc" ]; then
    if grep -qE '_authToken' "$dir/.npmrc" 2>/dev/null; then
      printf 'FAIL .npmrc contains an auth token (_authToken): %s\n' "$dir/.npmrc" >&2; hard_hit=1
    else
      printf 'WARN project dir contains .npmrc (no token detected); confirm this is a project dir\n' >&2
    fi
  fi
  [ "$hard_hit" -eq 0 ] || return 1

  # Soft warnings.
  for t in .config .docker .gem .cargo; do
    [ -e "$dir/$t" ] && printf 'WARN project dir contains %s; confirm this is a project, not a home/config dir\n' "$t" >&2
  done

  printf 'PASS project dir mount source vetted: %s\n' "$dir"; return 0
}
