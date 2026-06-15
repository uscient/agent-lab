#!/usr/bin/env bash
# Sourced, not executed. Vets host directories before they are bind-mounted into the agent
# (project dir at /workspace, secrets dir at /run/agent-secrets). PASS on stdout, WARN/FAIL
# on stderr, non-zero return on a hard refusal. Hard refusals are NOT overridable by design:
# to use a sensitive dir inside the box, mount a scoped *copy*, never the real store.
#
# Canonicalize with `cd ... && pwd -P` (portable; resolves symlinks and `..`) rather than
# `realpath -m`, which BSD/macOS may lack.

# Generic hard-refusal vetter. On PASS sets AGENT_LAB_VETTED_DIR to the canonical path and
# returns 0; on a hard refusal prints FAIL to stderr and returns 1. Refuses: non-directory,
# the filesystem root, $HOME, ancestors of $HOME, well-known system paths, and any directory
# carrying credential material (.ssh/.aws/.gnupg/.kube/.git-credentials/.netrc/
# .password-store, or an .npmrc holding an auth token).
agent_lab_vet_dir() {
  local raw label dir home_canon t
  AGENT_LAB_VETTED_DIR=""
  raw="$1"; label="${2:-directory}"

  if [ ! -d "$raw" ]; then
    printf 'FAIL %s does not exist or is not a directory: %s\n' "$label" "$raw" >&2; return 1
  fi
  dir="$(cd -- "$raw" >/dev/null 2>&1 && pwd -P)" || dir=""
  if [ -z "$dir" ]; then
    printf 'FAIL cannot resolve %s: %s\n' "$label" "$raw" >&2; return 1
  fi
  home_canon="$(cd -- "${HOME:-/nonexistent}" >/dev/null 2>&1 && pwd -P)" || home_canon=""

  [ "$dir" = "/" ] && { printf 'FAIL refusing to use the filesystem root as %s\n' "$label" >&2; return 1; }
  if [ -n "$home_canon" ] && [ "$dir" = "$home_canon" ]; then
    printf 'FAIL refusing to use your home directory as %s: %s\n' "$label" "$dir" >&2; return 1
  fi
  if [ -n "$home_canon" ]; then
    case "$home_canon/" in
      "$dir"/*) printf 'FAIL %s is an ancestor of HOME (%s); too broad\n' "$label" "$dir" >&2; return 1 ;;
    esac
  fi
  case "$dir" in
    /home|/Users|/root|/etc|/var|/usr|/bin|/sbin|/lib|/lib64|/opt|/boot|/sys|/proc|/dev|/mnt|/media|/srv|/run)
      printf 'FAIL refusing to use a system path as %s: %s\n' "$label" "$dir" >&2; return 1 ;;
  esac
  for t in .ssh .aws .gnupg .kube .git-credentials .netrc .password-store; do
    if [ -e "$dir/$t" ]; then
      printf 'FAIL %s contains credential material (%s): %s\n' "$label" "$t" "$dir" >&2; return 1
    fi
  done
  if [ -e "$dir/.npmrc" ] && grep -qE '_authToken' "$dir/.npmrc" 2>/dev/null; then
    printf 'FAIL %s contains an .npmrc auth token (_authToken): %s\n' "$label" "$dir/.npmrc" >&2; return 1
  fi

  AGENT_LAB_VETTED_DIR="$dir"
  return 0
}

# Vets the project dir mounted RW at /workspace. Empty input is allowed (ephemeral volume).
# Layers project-specific soft warnings on top of the generic hard refusals.
agent_lab_guard_project_dir() {
  local raw dir t
  raw="${1:-}"
  if [ -z "$raw" ]; then
    printf 'PASS no project dir set; using ephemeral workspace volume\n'; return 0
  fi
  agent_lab_vet_dir "$raw" "project dir" || return 1
  dir="$AGENT_LAB_VETTED_DIR"
  if [ -e "$dir/.npmrc" ]; then
    printf 'WARN project dir contains .npmrc (no token detected); confirm this is a project dir\n' >&2
  fi
  for t in .config .docker .gem .cargo; do
    [ -e "$dir/$t" ] && printf 'WARN project dir contains %s; confirm this is a project, not a home/config dir\n' "$t" >&2
  done
  printf 'PASS project dir mount source vetted: %s\n' "$dir"; return 0
}

# Vets the secrets dir bind-mounted read-only at /run/agent-secrets. A repo-local dir is
# created if missing and accepted after the credential-material check; an out-of-repo dir
# must already exist and pass the full hard-refusal vetter.
agent_lab_guard_secrets_dir() {
  local raw abs repo_canon parent_canon leaf canon
  raw="${1:-./secrets}"
  case "$raw" in
    /*) abs="$raw" ;;
    *)  abs="${REPO_ROOT:?REPO_ROOT not set}/${raw#./}" ;;
  esac
  repo_canon="$(cd -- "${REPO_ROOT}" >/dev/null 2>&1 && pwd -P)" || repo_canon=""
  parent_canon="$(cd -- "$(dirname -- "$abs")" >/dev/null 2>&1 && pwd -P)" || parent_canon=""
  if [ -z "$parent_canon" ]; then
    printf 'FAIL secrets dir parent does not exist: %s\n' "$(dirname -- "$abs")" >&2; return 1
  fi
  leaf="$(basename -- "$abs")"
  if [ -d "$abs" ]; then
    canon="$(cd -- "$abs" >/dev/null 2>&1 && pwd -P)" || canon="${parent_canon}/${leaf}"
  else
    canon="${parent_canon}/${leaf}"
  fi

  if [ -n "$repo_canon" ]; then
    case "${canon}/" in
      "${repo_canon}"/*)
        mkdir -p "$canon" || { printf 'FAIL cannot create secrets dir: %s\n' "$canon" >&2; return 1; }
        agent_lab_vet_dir "$canon" "secrets dir" || return 1
        printf 'PASS secrets dir vetted (repo-local): %s\n' "$AGENT_LAB_VETTED_DIR"; return 0 ;;
    esac
  fi

  agent_lab_vet_dir "$abs" "secrets dir" || return 1
  printf 'PASS secrets dir vetted: %s\n' "$AGENT_LAB_VETTED_DIR"; return 0
}
