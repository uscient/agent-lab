#!/usr/bin/env bash

AGENT_LAB_SECRET_PATTERN='([A-Z0-9_]*(TOKEN|SECRET|API[_-]?KEY|PRIVATE[_-]?KEY|ACCESS[_-]?KEY)[A-Z0-9_]*[[:space:]]*(=[[:space:]]*|:[[:space:]]+)["'\'']?[A-Za-z0-9_./+=-]{16,}|BEGIN (RSA |OPENSSH |EC |DSA |)PRIVATE KEY)'
AGENT_LAB_SAFE_SECRET_PATH_PATTERN='(^|[^A-Za-z0-9_])((AGENT_LAB_SECRETS_MOUNT[[:space:]]*(=[[:space:]]*|:[[:space:]]+)["'\'']?/run/agent-secrets)|(OPENCLAW_AUTH_SECRET_DIR[[:space:]]*=[[:space:]]*["'\'']?/home/node/[.]config/openclaw))["'\'']?([[:space:]]|$)'

agent_lab_tracked_source_has_secret_pattern() {
  local repo_root="$1"
  local candidate
  local candidate_without_safe
  local candidates
  local grep_rc=0

  if ! git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 0
  fi

  candidates="$(
    cd "$repo_root" &&
      git grep -I -n -E "$AGENT_LAB_SECRET_PATTERN" -- . 2>/dev/null
  )" || grep_rc=$?

  case "$grep_rc" in
    0) ;;
    1) return 1 ;;
    *) return 0 ;;
  esac

  while IFS= read -r candidate; do
    if ! candidate_without_safe="$(
      printf '%s\n' "$candidate" |
        sed -E \
          -e ':again' \
          -e "s@$AGENT_LAB_SAFE_SECRET_PATH_PATTERN@\\1\\6@" \
          -e 't again'
    )"; then
      return 0
    fi
    if printf '%s\n' "$candidate_without_safe" |
      grep -Eq "$AGENT_LAB_SECRET_PATTERN"; then
      return 0
    fi
  done <<< "$candidates"

  return 1
}
