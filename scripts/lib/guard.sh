#!/usr/bin/env bash
# Sourced, not executed. Pure path guards for host directories later bind-mounted into
# the agent. Guards export the canonical paths they actually checked; they never create
# directories. Materialization happens only after every configuration check has passed.

AGENT_LAB_VETTED_DIR=""
AGENT_LAB_VETTED_IDENTITY=""
AGENT_LAB_PROJECT_IDENTITY=""
AGENT_LAB_SECRETS_IDENTITY=""

agent_lab_dir_identity() {
  local output
  if output="$(stat -c '%d:%i' "$1" 2>/dev/null)"; then
    printf '%s\n' "$output"
  elif output="$(stat -f '%d:%i' "$1" 2>/dev/null)"; then
    printf '%s\n' "$output"
  else
    printf 'FAIL stat with device/inode output is required\n' >&2
    return 1
  fi
}

agent_lab_path_from_repo() {
  local raw
  raw="$1"
  case "$raw" in
    /*) printf '%s\n' "$raw" ;;
    *) printf '%s/%s\n' "${REPO_ROOT:?REPO_ROOT not set}" "${raw#./}" ;;
  esac
}

agent_lab_path_has_credential_component() {
  case "$1/" in
    */.ssh/*|*/.aws/*|*/.azure/*|*/.config/*|*/.docker/*|*/.gcloud/*|*/.gnupg/*|\
    */.kube/*|*/.cargo/*|*/.gem/*|*/.git-credentials/*|*/.netrc/*|*/.password-store/*)
      return 0
      ;;
  esac
  return 1
}

# On PASS, sets AGENT_LAB_VETTED_DIR and AGENT_LAB_VETTED_IDENTITY.
agent_lab_vet_dir() {
  local raw label dir home_canon identity t credential_file
  AGENT_LAB_VETTED_DIR=""
  AGENT_LAB_VETTED_IDENTITY=""
  raw="$1"
  label="${2:-directory}"

  if [ ! -d "$raw" ]; then
    printf 'FAIL %s does not exist or is not a directory: %s\n' "$label" "$raw" >&2
    return 1
  fi
  dir="$(cd -- "$raw" >/dev/null 2>&1 && pwd -P)" || dir=""
  if [ -z "$dir" ]; then
    printf 'FAIL cannot resolve %s: %s\n' "$label" "$raw" >&2
    return 1
  fi
  identity="$(agent_lab_dir_identity "$dir")" || return 1
  case "$dir" in
    *[[:cntrl:]]*|*:*)
      printf 'FAIL canonical %s cannot be represented safely as a Compose mount: %s\n' \
        "$label" "$dir" >&2
      return 1
      ;;
  esac
  home_canon="$(cd -- "${HOME:-/nonexistent}" >/dev/null 2>&1 && pwd -P)" ||
    home_canon=""
  if [ -z "$home_canon" ]; then
    printf 'FAIL cannot resolve HOME while vetting %s\n' "$label" >&2
    return 1
  fi

  if [ "$dir" = / ]; then
    printf 'FAIL refusing to use the filesystem root as %s\n' "$label" >&2
    return 1
  fi
  if [ -n "$home_canon" ] && [ "$dir" = "$home_canon" ]; then
    printf 'FAIL refusing to use your home directory as %s: %s\n' "$label" "$dir" >&2
    return 1
  fi
  if [ -n "$home_canon" ]; then
    case "$home_canon/" in
      "$dir"/*)
        printf 'FAIL %s is an ancestor of HOME (%s); too broad\n' "$label" "$dir" >&2
        return 1
        ;;
    esac
  fi
  case "$dir" in
    /home/*|/Users/*)
      case "$dir/" in
        "$home_canon"/*) ;;
        *)
          printf 'FAIL refusing to use another user home as %s: %s\n' "$label" "$dir" >&2
          return 1
          ;;
      esac
      ;;
  esac
  case "$dir" in
    /home|/Users|/root|/root/*|/etc|/etc/*|/private|/private/etc|/private/etc/*|\
    /var|/var/lib|/var/lib/*|/var/log|/var/log/*|/var/run|/var/run/*|/var/tmp|\
    /var/spool|/var/spool/*|/var/cache|/var/cache/*|\
    /private/var|/private/var/db|/private/var/db/*|/private/var/log|/private/var/log/*|\
    /private/var/run|/private/var/run/*|/private/var/tmp|\
    /usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|\
    /lib|/lib/*|/lib64|/lib64/*|/opt|/boot|/boot/*|/sys|/sys/*|\
    /proc|/proc/*|/dev|/dev/*|/mnt|/media|/srv|/Volumes|\
    /run|/run/*|/System|/System/*|/Library|/Library/*|/tmp|/private/tmp)
      printf 'FAIL refusing to use a system path as %s: %s\n' "$label" "$dir" >&2
      return 1
      ;;
  esac
  if agent_lab_path_has_credential_component "$dir"; then
    printf 'FAIL %s is inside a credential store: %s\n' "$label" "$dir" >&2
    return 1
  fi
  for t in .ssh .aws .azure .gcloud .gnupg .kube .git-credentials .netrc .password-store; do
    if [ -e "$dir/$t" ] || [ -L "$dir/$t" ]; then
      printf 'FAIL %s contains credential material (%s): %s\n' "$label" "$t" "$dir" >&2
      return 1
    fi
  done
  for credential_file in \
    .docker/config.json \
    .config/gh/hosts.yml \
    .config/gcloud/credentials.db \
    .cargo/credentials \
    .cargo/credentials.toml \
    .gem/credentials; do
    if [ -e "$dir/$credential_file" ] || [ -L "$dir/$credential_file" ]; then
      printf 'FAIL %s contains credential material (%s): %s\n' \
        "$label" "$credential_file" "$dir" >&2
      return 1
    fi
  done
  if [ -e "$dir/.npmrc" ] || [ -L "$dir/.npmrc" ]; then
    if [ ! -f "$dir/.npmrc" ] || [ -L "$dir/.npmrc" ] || [ ! -r "$dir/.npmrc" ]; then
      printf 'FAIL %s contains an unsafe .npmrc object: %s\n' "$label" "$dir/.npmrc" >&2
      return 1
    fi
    if grep -qiE '(^|[[:space:]])[^#]*(_authToken|_auth|_password)[[:space:]]*=' \
         "$dir/.npmrc"; then
      printf 'FAIL %s contains npm credential material: %s\n' "$label" "$dir/.npmrc" >&2
      return 1
    else
      case "$?" in
        1) ;;
        *)
          printf 'FAIL cannot inspect %s .npmrc safely\n' "$label" >&2
          return 1
          ;;
      esac
    fi
  fi

  AGENT_LAB_VETTED_DIR="$dir"
  AGENT_LAB_VETTED_IDENTITY="$identity"
  return 0
}

# Empty project input selects the named workspace volume. Nonempty relative paths are
# resolved against REPO_ROOT, matching Compose's path base, then canonicalized and exported.
agent_lab_guard_project_dir() {
  local raw candidate dir t
  raw="${1-}"
  AGENT_LAB_PROJECT_DIR=""
  AGENT_LAB_PROJECT_IDENTITY=""
  if [ -z "$raw" ]; then
    AGENT_LAB_PROJECT_DIR=""
    AGENT_LAB_PROJECT_IDENTITY=""
    export AGENT_LAB_PROJECT_DIR
    printf 'PASS no project dir set; using ephemeral workspace volume\n'
    return 0
  fi
  candidate="$(agent_lab_path_from_repo "$raw")" || return 1
  agent_lab_vet_dir "$candidate" "project dir" || return 1
  dir="$AGENT_LAB_VETTED_DIR"
  if [ -e "$dir/.npmrc" ]; then
    printf 'WARN project dir contains .npmrc (no token detected); confirm this is a project dir\n' >&2
  fi
  for t in .config .docker .gem .cargo; do
    [ -e "$dir/$t" ] &&
      printf 'WARN project dir contains %s; confirm this is a project, not a home/config dir\n' \
        "$t" >&2
  done
  AGENT_LAB_PROJECT_DIR="$dir"
  # shellcheck disable=SC2034 # consumed by scripts/agent after this sourced function returns.
  AGENT_LAB_PROJECT_IDENTITY="$AGENT_LAB_VETTED_IDENTITY"
  export AGENT_LAB_PROJECT_DIR
  printf 'PASS project dir mount source vetted: %s\n' "$dir"
}

# A missing secrets directory is accepted only as one prospective repo-local leaf whose
# parent already exists. It is not created here. Existing paths are canonicalized exactly
# like project paths, including symlink resolution and credential checks.
agent_lab_guard_secrets_dir() {
  local raw candidate repo_canon parent_raw parent_canon parent_identity leaf canon
  raw="${1:-./secrets}"
  AGENT_LAB_SECRETS_DIR=""
  AGENT_LAB_SECRETS_IDENTITY=""
  candidate="$(agent_lab_path_from_repo "$raw")" || return 1
  repo_canon="$(cd -- "${REPO_ROOT:?REPO_ROOT not set}" >/dev/null 2>&1 && pwd -P)" ||
    repo_canon=""
  [ -n "$repo_canon" ] || {
    printf 'FAIL cannot resolve repository root for secrets guard\n' >&2
    return 1
  }

  if [ -L "$candidate" ] && [ ! -e "$candidate" ]; then
    printf 'FAIL secrets dir is a broken symlink: %s\n' "$candidate" >&2
    return 1
  fi
  if [ -e "$candidate" ] || [ -L "$candidate" ]; then
    agent_lab_vet_dir "$candidate" "secrets dir" || return 1
    case "$repo_canon/" in
      "$AGENT_LAB_VETTED_DIR"/*)
        printf 'FAIL secrets dir must not equal or contain the repository root\n' >&2
        return 1
        ;;
    esac
    AGENT_LAB_SECRETS_DIR="$AGENT_LAB_VETTED_DIR"
    AGENT_LAB_SECRETS_IDENTITY="$AGENT_LAB_VETTED_IDENTITY"
    export AGENT_LAB_SECRETS_DIR
    printf 'PASS secrets dir vetted: %s\n' "$AGENT_LAB_SECRETS_DIR"
    return 0
  fi

  parent_raw="$(dirname -- "$candidate")"
  parent_canon="$(cd -- "$parent_raw" >/dev/null 2>&1 && pwd -P)" || parent_canon=""
  if [ -z "$parent_canon" ]; then
    printf 'FAIL secrets dir parent does not exist: %s\n' "$parent_raw" >&2
    return 1
  fi
  leaf="$(basename -- "$candidate")"
  case "$leaf" in
    ''|.|..)
      printf 'FAIL secrets dir must name one non-special directory leaf\n' >&2
      return 1
      ;;
  esac
  canon="${parent_canon}/${leaf}"
  case "$canon" in
    *[[:cntrl:]]*|*:*)
      printf 'FAIL canonical secrets path cannot be represented safely as a Compose mount\n' >&2
      return 1
      ;;
  esac
  case "$canon/" in
    "$repo_canon"/*) ;;
    *)
      printf 'FAIL a missing secrets dir must be a direct or nested repo-local path: %s\n' \
        "$canon" >&2
      return 1
      ;;
  esac
  if agent_lab_path_has_credential_component "$canon"; then
    printf 'FAIL secrets dir is inside a credential store: %s\n' "$canon" >&2
    return 1
  fi
  parent_identity="$(agent_lab_dir_identity "$parent_canon")" || return 1
  AGENT_LAB_SECRETS_DIR="$canon"
  # shellcheck disable=SC2034 # consumed by scripts/agent after this sourced function returns.
  AGENT_LAB_SECRETS_IDENTITY="missing:${parent_identity}:${leaf}"
  export AGENT_LAB_SECRETS_DIR
  printf 'PASS secrets dir vetted for later creation: %s\n' "$canon"
}

agent_lab_guard_mount_relationship() {
  local project secrets
  project="${AGENT_LAB_PROJECT_DIR}"
  secrets="${AGENT_LAB_SECRETS_DIR}"
  [ -z "$project" ] && return 0
  if [ -n "$AGENT_LAB_PROJECT_IDENTITY" ] &&
     [ "$AGENT_LAB_PROJECT_IDENTITY" = "$AGENT_LAB_SECRETS_IDENTITY" ]; then
    printf 'FAIL project and secrets resolve to the same directory identity\n' >&2
    return 1
  fi
  case "$secrets/" in
    "$project"|"$project"/*)
      printf 'FAIL secrets dir must not equal or be inside the writable project mount\n' >&2
      return 1
      ;;
  esac
  case "$project/" in
    "$secrets"|"$secrets"/*)
      printf 'FAIL project dir must not equal or be inside the secrets mount\n' >&2
      return 1
      ;;
  esac
  printf 'PASS project and secrets mount sources are disjoint\n'
}

# Create only the previously planned secrets leaf, then return through the same guard.
agent_lab_materialize_secrets_dir() {
  local expected expected_identity parent parent_identity post_parent_identity
  local leaf current_missing_identity was_missing
  expected="$1"
  expected_identity="$2"
  was_missing=0
  case "$expected_identity" in
    missing:*) was_missing=1 ;;
  esac

  agent_lab_guard_secrets_dir "$expected" || return 1
  if [ "${AGENT_LAB_SECRETS_DIR}" != "$expected" ] ||
     [ "${AGENT_LAB_SECRETS_IDENTITY}" != "$expected_identity" ]; then
    printf 'FAIL secrets path identity changed before materialization\n' >&2
    return 1
  fi
  if [ "$was_missing" -eq 1 ]; then
    parent="$(dirname -- "$expected")"
    [ -d "$parent" ] || {
      printf 'FAIL planned secrets parent disappeared: %s\n' "$parent" >&2
      return 1
    }
    parent_identity="$(agent_lab_dir_identity "$parent")" || return 1
    leaf="$(basename -- "$expected")" || return 1
    current_missing_identity="missing:${parent_identity}:${leaf}"
    if [ "$current_missing_identity" != "$expected_identity" ]; then
      printf 'FAIL planned secrets parent identity changed before creation\n' >&2
      return 1
    fi
    if ! mkdir -m 0700 -- "$expected"; then
      printf 'FAIL cannot create planned secrets dir: %s\n' "$expected" >&2
      return 1
    fi
    post_parent_identity="$(agent_lab_dir_identity "$parent")" || return 1
    if [ "$post_parent_identity" != "$parent_identity" ]; then
      printf 'FAIL planned secrets parent identity changed during creation\n' >&2
      return 1
    fi
  elif [ ! -d "$expected" ]; then
    printf 'FAIL planned existing secrets dir disappeared: %s\n' "$expected" >&2
    return 1
  fi
  agent_lab_guard_secrets_dir "$expected" || return 1
  [ "${AGENT_LAB_SECRETS_DIR}" = "$expected" ] || {
    printf 'FAIL secrets path changed while it was being materialized\n' >&2
    return 1
  }
  if [ "$was_missing" -eq 0 ] &&
     [ "${AGENT_LAB_SECRETS_IDENTITY}" != "$expected_identity" ]; then
    printf 'FAIL existing secrets identity changed during materialization\n' >&2
    return 1
  fi
}
