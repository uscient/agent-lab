#!/usr/bin/env bash
# Sourced constants for the Agent Lab Serena development tool.

# shellcheck disable=SC2034 # public constants consumed by sourcing scripts
AGENT_LAB_SERENA_VERSION="1.6.2.dev0"
AGENT_LAB_SERENA_REF="6c1c9653700cbe644cb5a5b026b77db2f4071c36"
AGENT_LAB_SERENA_TAG="agent-lab/serena:1.6.2-dev-6c1c9653"

agent_lab_serena_fail() {
  printf 'Serena MCP: %s\n' "$*" >&2
  return 125
}

agent_lab_serena_validate_identity() {
  local uid gid value label
  uid="$1"
  gid="$2"

  for label in UID GID; do
    if [ "$label" = UID ]; then value="$uid"; else value="$gid"; fi
    if [[ ! "$value" =~ ^[1-9][0-9]*$ ]] ||
       [ "${#value}" -gt 10 ] ||
       [ "$value" -gt 2147483647 ]; then
      agent_lab_serena_fail \
        "refusing non-canonical or root $label '$value'"
      return 125
    fi
  done
}

agent_lab_serena_validate_relative_mount() {
  local relative_path="$1"
  case "$relative_path" in
    "" | "." | ".." | /* | ./* | */./* | */. | \
      *$'\n'* | *$'\r'* | *$'\t'* | *"'"* | ../* | */../* | */..)
      agent_lab_serena_fail "unsafe repository-relative mount path"
      return 125
      ;;
  esac
}

agent_lab_serena_emit_bind() {
  local override_file="$1" source_path="$2" target_path="$3" writable="$4"
  case "$source_path$target_path" in
    *$'\n'* | *$'\r'* | *$'\t'* | *"'"*)
      agent_lab_serena_fail "mount path contains unsupported characters"
      return 125
      ;;
  esac

  {
    printf '      - type: bind\n'
    printf "        source: '%s'\n" "$source_path"
    printf "        target: '%s'\n" "$target_path"
    if [ "$writable" = 1 ]; then
      printf '        read_only: false\n'
    else
      printf '        read_only: true\n'
    fi
    printf '        bind:\n'
    printf '          create_host_path: false\n'
    printf '          propagation: rprivate\n'
    printf '          recursive: disabled\n'
  } >> "$override_file"
}

agent_lab_serena_require_mount_type() {
  local path="$1" expected_type="$2" label="$3"
  if [ -L "$path" ]; then
    agent_lab_serena_fail "$label is a symlink; refusing ambiguous mount input"
    return 125
  fi
  case "$expected_type" in
    directory)
      [ -d "$path" ] || {
        agent_lab_serena_fail "$label is not a directory"
        return 125
      }
      ;;
    file)
      [ -f "$path" ] || {
        agent_lab_serena_fail "$label is not a regular file"
        return 125
      }
      ;;
    *)
      agent_lab_serena_fail "internal mount-type error"
      return 125
      ;;
  esac
}

agent_lab_serena_reject_child_mounts() {
  local repo_root="$1" mountinfo_path="${2:-/proc/self/mountinfo}"
  local canonical_repo_root mount_line mount_target relative
  local mount_records=0
  local covering_mount=0
  local -a mount_fields=()

  canonical_repo_root="$(readlink -e -- "$repo_root")" || {
    agent_lab_serena_fail "cannot resolve the project root for mount inspection"
    return 125
  }
  [ -r "$mountinfo_path" ] || {
    agent_lab_serena_fail "cannot read process mount metadata"
    return 125
  }

  while IFS= read -r mount_line || [ -n "$mount_line" ]; do
    mount_fields=()
    read -r -a mount_fields <<< "$mount_line"
    if [ "${#mount_fields[@]}" -lt 6 ] ||
       [[ "$mount_line" != *" - "* ]] ||
       [[ "${mount_fields[4]}" != /* ]]; then
      agent_lab_serena_fail "process mount metadata is malformed"
      return 125
    fi
    mount_records=$((mount_records + 1))
    mount_target="${mount_fields[4]}"
    # Linux mountinfo escapes whitespace and backslashes in path fields.
    mount_target="${mount_target//\\040/ }"
    mount_target="${mount_target//\\011/$'\t'}"
    mount_target="${mount_target//\\012/$'\n'}"
    mount_target="${mount_target//\\134/\\}"

    if [ "$mount_target" = "$canonical_repo_root" ] ||
       [ "$mount_target" = "/" ] ||
       { [ "$mount_target" != "/" ] &&
         [[ "$canonical_repo_root" == "$mount_target/"* ]]; }; then
      covering_mount=1
    fi

    if { [ "$canonical_repo_root" = "/" ] &&
         [ "$mount_target" != "/" ] &&
         [[ "$mount_target" == /* ]]; } ||
       { [ "$canonical_repo_root" != "/" ] &&
         [[ "$mount_target" == "$canonical_repo_root/"* ]]; }; then
      if [ "$canonical_repo_root" = "/" ]; then
        relative="${mount_target#/}"
      else
        relative="${mount_target#"$canonical_repo_root"/}"
      fi
      printf \
        'Serena MCP: refusing child mount exposed by the project bind: host=%q container=%q\n' \
        "$mount_target" "/workspace/$relative" >&2
      return 125
    fi
  done < "$mountinfo_path"

  if [ "$mount_records" -eq 0 ]; then
    agent_lab_serena_fail "process mount metadata is empty"
    return 125
  fi
  if [ "$covering_mount" -ne 1 ]; then
    agent_lab_serena_fail "process mount metadata does not cover the project root"
    return 125
  fi
}

agent_lab_serena_reject_nested_git_objects() {
  local repo_root="$1" state_root="$2"
  local scan_file nested relative
  scan_file="$state_root/nested-git-paths"

  # Inspect names and object metadata only. The top-level .git object is
  # separately masked; any deeper .git object would remain visible.
  if ! find "$repo_root" -xdev \
      \( -path "$repo_root/.git" -prune \) -o \
      \( -mindepth 2 -name '.git' -print0 -prune \) > "$scan_file"; then
    agent_lab_serena_fail "cannot complete nested .git metadata scan"
    return 125
  fi

  if IFS= read -r -d '' nested < "$scan_file"; then
    relative="${nested#"$repo_root"/}"
    printf \
      'Serena MCP: refusing nested .git object exposed at %q\n' \
      "/workspace/$relative" >&2
    return 125
  fi
}

agent_lab_serena_reject_nested_sensitive_paths() {
  local repo_root="$1" state_root="$2" scan_file nested relative basename
  scan_file="$state_root/sensitive-paths"

  # Inspect names and object metadata only. Never descend into the Git directory,
  # masked local secrets, or masked runtime-state roots.
  if ! find "$repo_root" -xdev \
      \( -path "$repo_root/.git" \
         -o -path "$repo_root/secrets" \
         -o -path "$repo_root/data" \
         -o -path "$repo_root/volumes" \
         -o -path "$repo_root/runtime" \
         -o -path "$repo_root/logs" \
         -o -path "$repo_root/state" \
         -o -path "$repo_root/cache" \
         -o -path "$repo_root/.cache" \
         -o -path "$repo_root/models" \
         -o -path "$repo_root/browser-profiles" \
         -o -path "$repo_root/agent-state" \
         -o -path "$repo_root/.tmp" \
         -o -path "$repo_root/tmp" \
         -o -path "$repo_root/node_modules" \
         -o -path "$repo_root/.pytest_cache" \
         -o -path "$repo_root/__pycache__" \
         -o -path "$repo_root/.idea" \) -prune \
      -o -mindepth 1 \
      \( -name '.env' \
         -o -name '.env.*' \
         -o -name 'secrets' \
         -o -name '.ssh' \
         -o -name '.aws' \
         -o -name '.azure' \
         -o -name '.gcloud' \
         -o -name '.gnupg' \
         -o -name '.kube' \
         -o -name '.docker' \
         -o -name '.password-store' \
         -o -path '*/.config/git' \
         -o -path '*/.config/gh' \
         -o -path '*/.config/gcloud' \
         -o -path '*/.docker/config.json' \
         -o -path '*/.cargo/credentials*' \
         -o -path '*/.gem/credentials' \
         -o -name '.gitconfig' \
         -o -name '.git-credentials' \
         -o -name '.netrc' \
         -o -name '.npmrc' \
         -o -name 'credentials' \
         -o -name '.credentials' \
         -o -name 'credentials.json' \
         -o -name 'credential-store' \
         -o -name '*.pem' \
         -o -name '*.key' \
         -o -name '*.kdbx' \
         -o -name '*.p12' \
         -o -name '*.pfx' \
         -o -name '*.age' \
         -o -name '*.gpg' \) \
      -print0 > "$scan_file"; then
    agent_lab_serena_fail "cannot complete sensitive-path metadata scan"
    return 125
  fi

  while IFS= read -r -d '' nested; do
    relative="${nested#"$repo_root"/}"
    basename="${relative##*/}"
    case "$basename" in
      .env.example | .env.*.example) continue ;;
    esac
    case "$relative" in
      .env | .env.*) continue ;;
    esac
    printf 'Serena MCP: refusing nested credential, key, or env path: %q\n' \
      "$relative" >&2
    return 125
  done < "$scan_file"
}

agent_lab_serena_validate_shared_proj() {
  local repo_root="$1" state_root="$2" proj_root
  local object_scan hardlink_scan unsafe relative
  proj_root="$repo_root/proj"

  # This is a startup snapshot. The threat model requires cooperating host
  # writers to preserve the ordinary-file contract while Serena is running.
  if [ ! -e "$proj_root" ] && [ ! -L "$proj_root" ]; then
    return 0
  fi
  agent_lab_serena_require_mount_type \
    "$proj_root" directory "shared planning root proj" ||
    return 125

  object_scan="$state_root/proj-unsafe-objects"
  if ! find "$proj_root" -xdev -mindepth 1 \
      ! -type d ! -type f -print0 > "$object_scan"; then
    agent_lab_serena_fail "cannot complete shared proj object scan"
    return 125
  fi
  if IFS= read -r -d '' unsafe < "$object_scan"; then
    relative="${unsafe#"$repo_root"/}"
    printf \
      'Serena MCP: refusing symlink or special object in shared proj: %q\n' \
      "$relative" >&2
    return 125
  fi

  hardlink_scan="$state_root/proj-hardlinked-files"
  if ! find "$proj_root" -xdev -type f ! -links 1 \
      -print0 > "$hardlink_scan"; then
    agent_lab_serena_fail "cannot complete shared proj hardlink scan"
    return 125
  fi
  if IFS= read -r -d '' unsafe < "$hardlink_scan"; then
    relative="${unsafe#"$repo_root"/}"
    printf 'Serena MCP: refusing multiply linked file in shared proj: %q\n' \
      "$relative" >&2
    return 125
  fi
}

agent_lab_serena_prepare_mounts() {
  local repo_root="$1" state_root="$2"
  local empty_dir empty_file cache_dir override_file
  local git_source path basename relative expected_type
  local runtime_roots rail_entry rail_path unsafe_rail_object
  local env_candidates=()

  [ "${repo_root#/}" != "$repo_root" ] || {
    agent_lab_serena_fail "project root must be absolute"
    return 125
  }
  agent_lab_serena_require_mount_type "$repo_root" directory "project root" ||
    return 125
  agent_lab_serena_require_mount_type \
    "$repo_root/policy/protected.paths" file "protected-path policy" ||
    return 125
  agent_lab_serena_require_mount_type "$state_root" directory "mask state root" ||
    return 125
  agent_lab_serena_validate_shared_proj "$repo_root" "$state_root" ||
    return 125

  agent_lab_serena_reject_child_mounts "$repo_root" /proc/self/mountinfo ||
    return 125
  agent_lab_serena_reject_nested_git_objects "$repo_root" "$state_root" ||
    return 125

  empty_dir="$state_root/empty-dir"
  empty_file="$state_root/empty-file"
  cache_dir="$state_root/project-cache"
  override_file="$state_root/compose.mounts.yaml"
  install -d -m 0555 "$empty_dir"
  install -d -m 0700 "$cache_dir"
  : > "$empty_file"
  chmod 0444 "$empty_file"
  {
    printf 'services:\n'
    printf '  serena:\n'
    printf '    volumes:\n'
  } > "$override_file"

  if [ -L "$repo_root/.git" ]; then
    agent_lab_serena_fail ".git is a symlink; refusing ambiguous mount input"
    return 125
  elif [ -d "$repo_root/.git" ]; then
    git_source="$empty_dir"
  elif [ -f "$repo_root/.git" ]; then
    git_source="$empty_file"
  else
    agent_lab_serena_fail ".git is missing or is a special object"
    return 125
  fi

  shopt -s nullglob
  env_candidates=("$repo_root"/.env "$repo_root"/.env.*)
  shopt -u nullglob
  for path in "${env_candidates[@]}"; do
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then
      continue
    fi
    basename="${path##*/}"
    case "$basename" in
      .env.example | .env.*.example) continue ;;
    esac
    agent_lab_serena_require_mount_type \
      "$path" file "local environment path $basename" ||
      return 125
    agent_lab_serena_emit_bind \
      "$override_file" "$empty_file" "/workspace/$basename" 0 ||
      return 125
  done

  if [ -e "$repo_root/secrets" ] || [ -L "$repo_root/secrets" ]; then
    agent_lab_serena_require_mount_type \
      "$repo_root/secrets" directory "repo-local secrets path" ||
      return 125
    agent_lab_serena_emit_bind \
      "$override_file" "$empty_dir" "/workspace/secrets" 0 ||
      return 125
  fi

  runtime_roots=(
    data volumes runtime logs state cache .cache models browser-profiles
    agent-state .tmp tmp node_modules .pytest_cache __pycache__ .idea
  )
  for relative in "${runtime_roots[@]}"; do
    path="$repo_root/$relative"
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then
      continue
    fi
    agent_lab_serena_require_mount_type \
      "$path" directory "runtime-state root $relative" ||
      return 125
    agent_lab_serena_emit_bind \
      "$override_file" "$empty_dir" "/workspace/$relative" 0 ||
      return 125
  done

  agent_lab_serena_reject_nested_sensitive_paths "$repo_root" "$state_root" ||
    return 125

  while IFS= read -r rail_entry || [ -n "$rail_entry" ]; do
    case "$rail_entry" in
      "" | \#*) continue ;;
    esac
    agent_lab_serena_validate_relative_mount "$rail_entry" || return 125
    relative="${rail_entry%/}"
    rail_path="$repo_root/$relative"
    if [ ! -e "$rail_path" ] && [ ! -L "$rail_path" ]; then
      continue
    fi
    case "$rail_entry" in
      */) expected_type="directory" ;;
      *) expected_type="file" ;;
    esac
    agent_lab_serena_require_mount_type \
      "$rail_path" "$expected_type" "protected rail $relative" ||
      return 125
    if [ "$expected_type" = directory ]; then
      unsafe_rail_object="$state_root/unsafe-rail-object"
      if ! find "$rail_path" -xdev \
          \( -type l -o \( ! -type d -a ! -type f \) \) \
          -print -quit > "$unsafe_rail_object"; then
        agent_lab_serena_fail \
          "cannot inspect protected rail metadata for $relative"
        return 125
      fi
      if [ -s "$unsafe_rail_object" ]; then
        agent_lab_serena_fail \
          "protected rail $relative contains a symlink or special object"
        return 125
      fi
    fi
    agent_lab_serena_emit_bind \
      "$override_file" "$rail_path" "/workspace/$relative" 0 ||
      return 125
  done < "$repo_root/policy/protected.paths"

  AGENT_LAB_SERENA_GIT_MASK_SOURCE="$git_source"
  AGENT_LAB_SERENA_CACHE_DIR="$cache_dir"
  AGENT_LAB_SERENA_MOUNT_OVERRIDE="$override_file"
  export AGENT_LAB_SERENA_GIT_MASK_SOURCE
  export AGENT_LAB_SERENA_CACHE_DIR
  export AGENT_LAB_SERENA_MOUNT_OVERRIDE
}
