#!/usr/bin/env bash
# Sourced, not executed. Single source of config authority for the BYOA seams.
#
# Why this exists: scripts/agent guards values and invokes Compose with `--env-file`, which
# Compose reads independently. If the script read seams from the shell env only, a value set
# ONLY in .env.local (e.g. AGENT_LAB_PROJECT_DIR=$HOME) would pass the guard on an empty value
# while Compose still mounted it. This loader closes that gap: it computes each key's EFFECTIVE
# value (shell env > strictly-parsed env-file > documented default), rejects env-file values
# that carry shell metacharacters, and EXPORTS every key. Because a shell export overrides the
# same key in `--env-file`, Compose then consumes exactly these validated values and can never
# reach an unvalidated .env.local value. The env-file is NEVER sourced (it may contain code).

# Documented default for a BYOA key (must match the compose `${VAR:-default}` fallbacks).
agent_lab_byoa_default() {
  case "$1" in
    AGENT_LAB_SECRETS_DIR)       printf './secrets' ;;
    AGENT_LAB_EPHEMERAL_HOME)    printf '0' ;;
    AGENT_LAB_ALLOWLIST_RECIPES) printf 'base' ;;
    AGENT_LAB_AGENT_UID)         printf '1000' ;;
    AGENT_LAB_AGENT_GID)         printf '1000' ;;
    AGENT_LAB_AGENT_MEM)         printf '4g' ;;
    AGENT_LAB_AGENT_CPUS)        printf '2' ;;
    *)                           printf '' ;;   # AGENT_LAB_AGENT_IMAGE, AGENT_LAB_PROJECT_DIR
  esac
}

# Strictly read KEY's value from an env-file WITHOUT executing it.
#   stdout: the validated value (may be empty)
#   return: 0 found+valid | 1 not present | 2 present but rejected (message on stderr)
agent_lab_envfile_value() {
  local file="$1" key="$2" line value
  [ -f "$file" ] || return 1
  # Last assignment wins, mirroring shell/Compose precedence. Allow an optional `export `.
  line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" 2>/dev/null | tail -n 1)" || true
  [ -n "$line" ] || return 1
  value="${line#*=}"                       # everything after the first '='
  case "$value" in                         # strip one layer of surrounding matching quotes
    \"*\") value="${value#\"}"; value="${value%\"}" ;;
    \'*\') value="${value#\'}"; value="${value%\'}" ;;
  esac
  case "$value" in                         # reject shell metacharacters (injection defense)
    *'$'*|*'`'*|*';'*|*'&'*|*'|'*|*'<'*|*'>'*|*'('*|*')'*)
      printf 'FAIL %s in %s contains shell metacharacters; refusing\n' "$key" "$file" >&2
      return 2 ;;
  esac
  printf '%s' "$value"
  return 0
}

# Compute and export the effective value of every BYOA key. $1 = env-file path.
# Returns non-zero (aborting the caller) if any env-file value is rejected.
agent_lab_load_byoa_config() {
  local file key rc fileval
  local keys=(
    AGENT_LAB_AGENT_IMAGE AGENT_LAB_PROJECT_DIR AGENT_LAB_SECRETS_DIR
    AGENT_LAB_EPHEMERAL_HOME AGENT_LAB_ALLOWLIST_RECIPES
    AGENT_LAB_AGENT_UID AGENT_LAB_AGENT_GID AGENT_LAB_AGENT_MEM AGENT_LAB_AGENT_CPUS
  )
  file="$1"
  for key in "${keys[@]}"; do
    if [ -n "${!key+x}" ]; then
      : # set in the real shell environment: authoritative, used as-is
    else
      rc=0
      fileval="$(agent_lab_envfile_value "$file" "$key")" || rc=$?
      case "$rc" in
        0) printf -v "$key" '%s' "$fileval" ;;
        1) printf -v "$key" '%s' "$(agent_lab_byoa_default "$key")" ;;
        *) return 1 ;;   # rejected: message already printed
      esac
    fi
    # shellcheck disable=SC2163  # export the variable *named by* $key (indirect, intentional)
    export "$key"
  done
}

# Reject root or non-numeric UID/GID; the agent must run non-root. Uses the effective values.
agent_lab_validate_uid_gid() {
  local uid gid
  uid="${AGENT_LAB_AGENT_UID}"
  gid="${AGENT_LAB_AGENT_GID}"
  case "$uid" in ''|*[!0-9]*) printf 'FAIL AGENT_LAB_AGENT_UID must be a number: %s\n' "$uid" >&2; return 1 ;; esac
  case "$gid" in ''|*[!0-9]*) printf 'FAIL AGENT_LAB_AGENT_GID must be a number: %s\n' "$gid" >&2; return 1 ;; esac
  if [ "$uid" -eq 0 ]; then printf 'FAIL refusing to run the agent as root (AGENT_LAB_AGENT_UID=0)\n' >&2; return 1; fi
  if [ "$gid" -eq 0 ]; then printf 'FAIL refusing GID 0 (AGENT_LAB_AGENT_GID=0)\n' >&2; return 1; fi
  printf 'PASS agent runs as non-root %s:%s\n' "$uid" "$gid"
  return 0
}
