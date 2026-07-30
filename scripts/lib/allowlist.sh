#!/usr/bin/env bash
# Sourced, not executed. Validates named allowlist recipes as pure data, then publishes
# one immutable content-addressed policy for Squid.

AGENT_LAB_VALIDATED_RECIPES=()
AGENT_LAB_VALIDATED_DOMAIN_RECIPES=()
AGENT_LAB_VALIDATED_DOMAINS=()
AGENT_LAB_VALIDATED_RECIPE_SET=""
AGENT_LAB_ALLOWLIST_PLAN_READY=0

agent_lab_sha256_file() {
  local output hash
  if command -v sha256sum >/dev/null 2>&1; then
    output="$(sha256sum "$1")" || {
      printf 'FAIL cannot hash allowlist file: %s\n' "$1" >&2
      return 1
    }
  elif command -v shasum >/dev/null 2>&1; then
    output="$(shasum -a 256 "$1")" || {
      printf 'FAIL cannot hash allowlist file: %s\n' "$1" >&2
      return 1
    }
  else
    printf 'FAIL SHA-256 tool required (sha256sum or shasum)\n' >&2
    return 1
  fi
  hash="${output%%[[:space:]]*}"
  if [ "${#hash}" -ne 64 ]; then
    printf 'FAIL SHA-256 tool returned an invalid digest\n' >&2
    return 1
  fi
  case "$hash" in
    *[!0-9a-f]*)
      printf 'FAIL SHA-256 tool returned an invalid digest\n' >&2
      return 1
      ;;
  esac
  printf '%s\n' "$hash"
}

agent_lab_allowlist_dir_identity() {
  if stat -c '%d:%i' "$1" >/dev/null 2>&1; then
    stat -c '%d:%i' "$1"
  elif stat -f '%d:%i' "$1" >/dev/null 2>&1; then
    stat -f '%d:%i' "$1"
  else
    printf 'FAIL stat with device/inode output is required\n' >&2
    return 1
  fi
}

agent_lab_allowlist_file_mode() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  elif stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    return 1
  fi
}

# Read-only readiness check used before scripts/agent materializes either secrets or cache.
agent_lab_preflight_allowlist_publication() {
  local cache_dir out_dir parent
  if ! command -v sha256sum >/dev/null 2>&1 &&
     ! command -v shasum >/dev/null 2>&1; then
    printf 'FAIL SHA-256 tool required (sha256sum or shasum)\n' >&2
    return 1
  fi
  cache_dir="${REPO_ROOT:?REPO_ROOT not set}/.cache"
  out_dir="${cache_dir}/squid"
  for parent in "$cache_dir" "$out_dir"; do
    if [ -e "$parent" ] || [ -L "$parent" ]; then
      if [ ! -d "$parent" ] || [ -L "$parent" ] ||
         [ ! -w "$parent" ] || [ ! -x "$parent" ]; then
        printf 'FAIL allowlist cache path is not a writable non-symlink directory: %s\n' \
          "$parent" >&2
        return 1
      fi
    else
      parent="$(dirname -- "$parent")"
      while [ ! -e "$parent" ] && [ "$parent" != / ]; do
        parent="$(dirname -- "$parent")"
      done
      if [ ! -d "$parent" ] || [ -L "$parent" ] ||
         [ ! -w "$parent" ] || [ ! -x "$parent" ]; then
        printf 'FAIL allowlist cache parent cannot be safely created: %s\n' "$parent" >&2
        return 1
      fi
    fi
  done
  printf 'PASS allowlist publication prerequisites validated\n'
}

agent_lab_allowlist_domain_valid() {
  local value domain label labels
  value="$1"
  domain="${value#.}"
  [ -n "$domain" ] && [ "${#domain}" -le 253 ] || return 1
  case "$domain" in
    *.*) ;;
    *) return 1 ;;
  esac
  case "$domain" in
    .*|*.|*..*|*[!a-z0-9.-]*) return 1 ;;
  esac
  case "$domain" in
    *[!0-9.]*) ;;
    *) return 1 ;;
  esac
  IFS=. read -r -a labels <<< "$domain"
  for label in "${labels[@]}"; do
    [ -n "$label" ] && [ "${#label}" -le 63 ] || return 1
    case "$label" in
      -*|*-|*[!a-z0-9-]*) return 1 ;;
    esac
  done
  return 0
}

agent_lab_recipe_name_valid() {
  local name part parts
  name="$1"
  [ -n "$name" ] && [ "${#name}" -le 63 ] || return 1
  case "$name" in
    *[!a-z0-9-]*|-*|*-|*--*) return 1 ;;
  esac
  IFS=- read -r -a parts <<< "$name"
  for part in "${parts[@]}"; do
    [ -n "$part" ] || return 1
  done
  return 0
}

# Pure validation phase. It performs no mkdir, temporary-file, chmod, or cache operation.
# The exact validated recipe/domain records are retained in indexed arrays for the builder,
# so policy files are not reopened between validation and publication.
agent_lab_validate_allowlist_recipes() {
  local LC_ALL=C
  local recipes remaining recipe seen fragment line line_no domain_seen
  local -a planned_recipes=()
  local -a planned_domain_recipes=()
  local -a planned_domains=()
  AGENT_LAB_VALIDATED_RECIPES=()
  AGENT_LAB_VALIDATED_DOMAIN_RECIPES=()
  AGENT_LAB_VALIDATED_DOMAINS=()
  AGENT_LAB_VALIDATED_RECIPE_SET=""
  AGENT_LAB_ALLOWLIST_PLAN_READY=0

  if [ -z "${AGENT_LAB_ALLOWLIST_RECIPES+x}" ]; then
    printf 'FAIL AGENT_LAB_ALLOWLIST_RECIPES is not set\n' >&2
    return 1
  fi
  recipes="${AGENT_LAB_ALLOWLIST_RECIPES}"
  remaining="${recipes},"

  while [ -n "$remaining" ]; do
    recipe="${remaining%%,*}"
    remaining="${remaining#*,}"
    if [ -z "$recipe" ]; then
      printf 'FAIL allowlist recipe list contains an empty item\n' >&2
      return 1
    fi
    if ! agent_lab_recipe_name_valid "$recipe"; then
      printf 'FAIL invalid allowlist recipe name\n' >&2
      return 1
    fi
    if [ "${#planned_recipes[@]}" -gt 0 ]; then
      for seen in "${planned_recipes[@]}"; do
        if [ "$seen" = "$recipe" ]; then
          printf 'FAIL duplicate allowlist recipe: %s\n' "$recipe" >&2
          return 1
        fi
      done
    fi

    fragment="${REPO_ROOT:?REPO_ROOT not set}/policies/recipes/${recipe}.allowlist"
    if [ ! -f "$fragment" ] || [ ! -r "$fragment" ] || [ -L "$fragment" ]; then
      printf 'FAIL unknown or unsafe allowlist recipe: %s\n' "$recipe" >&2
      return 1
    fi
    if [ -L "${REPO_ROOT}/policies" ] || [ -L "${REPO_ROOT}/policies/recipes" ]; then
      printf 'FAIL allowlist recipe directory must not be a symlink\n' >&2
      return 1
    fi
    if ! cmp -s "$fragment" <(LC_ALL=C tr -d '\000' < "$fragment"); then
      printf 'FAIL NUL byte in allowlist recipe: %s\n' "$recipe" >&2
      return 1
    fi

    planned_recipes+=("$recipe")
    line_no=0
    while IFS= read -r line || [ -n "$line" ]; do
      line_no=$((line_no + 1))
      case "$line" in
        *$'\r'*)
          printf 'FAIL carriage return in allowlist recipe %s line %s\n' \
            "$recipe" "$line_no" >&2
          return 1
          ;;
      esac
      case "$line" in
        ''|'#'*) continue ;;
      esac
      if ! agent_lab_allowlist_domain_valid "$line"; then
        printf 'FAIL invalid domain in allowlist recipe %s line %s\n' \
          "$recipe" "$line_no" >&2
        return 1
      fi
      if [ "${#planned_domains[@]}" -gt 0 ]; then
        for domain_seen in "${planned_domains[@]}"; do
          if [ "$domain_seen" = "$line" ]; then
            printf 'FAIL duplicate allowlist domain: %s\n' "$line" >&2
            return 1
          fi
        done
      fi
      planned_domain_recipes+=("$recipe")
      planned_domains+=("$line")
    done < "$fragment"
  done

  AGENT_LAB_VALIDATED_RECIPES=("${planned_recipes[@]}")
  if [ "${#planned_domains[@]}" -gt 0 ]; then
    AGENT_LAB_VALIDATED_DOMAIN_RECIPES=("${planned_domain_recipes[@]}")
    AGENT_LAB_VALIDATED_DOMAINS=("${planned_domains[@]}")
  fi
  AGENT_LAB_VALIDATED_RECIPE_SET="$recipes"
  AGENT_LAB_ALLOWLIST_PLAN_READY=1
  printf 'PASS allowlist recipes and fragments validated: %s\n' "$recipes"
}

agent_lab_publish_validated_allowlist() {
  local recipes cache_dir out_dir out_dir_identity current_identity
  local tmp hash out existing_hash final_hash final_mode recipe i
  recipes="$AGENT_LAB_VALIDATED_RECIPE_SET"
  if [ "$AGENT_LAB_ALLOWLIST_PLAN_READY" -ne 1 ] ||
     [ "${#AGENT_LAB_VALIDATED_RECIPES[@]}" -eq 0 ]; then
    printf 'FAIL no validated allowlist recipe plan is available\n' >&2
    return 1
  fi
  if [ "${AGENT_LAB_ALLOWLIST_RECIPES-}" != "$recipes" ]; then
    printf 'FAIL allowlist recipe selection changed after validation\n' >&2
    return 1
  fi
  agent_lab_preflight_allowlist_publication >/dev/null || return 1

  cache_dir="${REPO_ROOT:?REPO_ROOT not set}/.cache"
  out_dir="${cache_dir}/squid"
  if { [ -e "$cache_dir" ] || [ -L "$cache_dir" ]; } &&
     { [ ! -d "$cache_dir" ] || [ -L "$cache_dir" ]; }; then
    printf 'FAIL allowlist cache root is not a safe directory: %s\n' "$cache_dir" >&2
    return 1
  fi
  if { [ -e "$out_dir" ] || [ -L "$out_dir" ]; } &&
     { [ ! -d "$out_dir" ] || [ -L "$out_dir" ]; }; then
    printf 'FAIL allowlist cache directory is not safe: %s\n' "$out_dir" >&2
    return 1
  fi
  if ! mkdir -p "$out_dir"; then
    printf 'FAIL cannot create allowlist cache directory: %s\n' "$out_dir" >&2
    return 1
  fi
  if [ -L "$cache_dir" ] || [ -L "$out_dir" ]; then
    printf 'FAIL allowlist cache path changed during creation\n' >&2
    return 1
  fi
  out_dir_identity="$(agent_lab_allowlist_dir_identity "$out_dir")" || return 1
  tmp="$(mktemp "${out_dir}/allowlist.XXXXXX")" || {
    printf 'FAIL cannot create temporary allowlist in %s\n' "$out_dir" >&2
    return 1
  }

  if ! {
    printf '# Generated by scripts/lib/allowlist.sh -- do not edit by hand.\n'
    printf '# Composed from recipes: %s\n' "$recipes"
    for recipe in "${AGENT_LAB_VALIDATED_RECIPES[@]}"; do
      printf '\n# --- recipe: %s ---\n' "$recipe"
      if [ "${#AGENT_LAB_VALIDATED_DOMAINS[@]}" -gt 0 ]; then
        for i in "${!AGENT_LAB_VALIDATED_DOMAINS[@]}"; do
          if [ "${AGENT_LAB_VALIDATED_DOMAIN_RECIPES[$i]}" = "$recipe" ]; then
            printf '%s\n' "${AGENT_LAB_VALIDATED_DOMAINS[$i]}"
          fi
        done
      fi
    done
  } > "$tmp"; then
    rm -f "$tmp"
    printf 'FAIL cannot write generated allowlist\n' >&2
    return 1
  fi

  hash="$(agent_lab_sha256_file "$tmp")" || {
    rm -f "$tmp"
    return 1
  }
  current_identity="$(agent_lab_allowlist_dir_identity "$out_dir")" || {
    rm -f "$tmp"
    return 1
  }
  if [ "$current_identity" != "$out_dir_identity" ]; then
    rm -f "$tmp"
    printf 'FAIL allowlist cache directory identity changed during publication\n' >&2
    return 1
  fi
  out="${out_dir}/allowlist.${hash}.txt"
  if [ -e "$out" ] || [ -L "$out" ]; then
    if [ ! -f "$out" ] || [ -L "$out" ]; then
      rm -f "$tmp"
      printf 'FAIL content-addressed allowlist path is unsafe: %s\n' "$out" >&2
      return 1
    fi
    existing_hash="$(agent_lab_sha256_file "$out")" || {
      rm -f "$tmp"
      return 1
    }
    if [ "$existing_hash" != "$hash" ]; then
      rm -f "$tmp"
      printf 'FAIL content-addressed allowlist was modified: %s\n' "$out" >&2
      return 1
    fi
    if ! chmod 0444 "$out"; then
      rm -f "$tmp"
      printf 'FAIL cannot protect existing allowlist: %s\n' "$out" >&2
      return 1
    fi
    rm -f "$tmp" || {
      printf 'FAIL cannot remove temporary allowlist: %s\n' "$tmp" >&2
      return 1
    }
  else
    if ! chmod 0444 "$tmp"; then
      rm -f "$tmp"
      printf 'FAIL cannot protect generated allowlist\n' >&2
      return 1
    fi
    if ! mv "$tmp" "$out"; then
      rm -f "$tmp"
      printf 'FAIL cannot publish generated allowlist: %s\n' "$out" >&2
      return 1
    fi
  fi

  current_identity="$(agent_lab_allowlist_dir_identity "$out_dir")" || return 1
  if [ "$current_identity" != "$out_dir_identity" ] ||
     [ ! -f "$out" ] || [ -L "$out" ]; then
    printf 'FAIL generated allowlist publication target is not the validated file\n' >&2
    return 1
  fi
  final_hash="$(agent_lab_sha256_file "$out")" || return 1
  final_mode="$(agent_lab_allowlist_file_mode "$out")" || {
    printf 'FAIL cannot verify generated allowlist permissions\n' >&2
    return 1
  }
  if [ "$final_hash" != "$hash" ] || [ "$final_mode" != 444 ]; then
    printf 'FAIL generated allowlist failed final hash or mode verification\n' >&2
    return 1
  fi

  printf 'PASS generated allowlist [%s] sha256=%s -> %s\n' "$recipes" "$hash" "$out"
  export AGENT_LAB_EGRESS_ALLOWLIST="$out"
  export AGENT_LAB_EGRESS_POLICY_SHA256="$hash"
}

# Defense-in-depth public entry point for callers that do not have a separate planning
# phase. scripts/agent validates early and later calls the publisher directly so the exact
# in-memory bytes it approved are consumed without reopening recipe fragments.
agent_lab_build_allowlist() {
  agent_lab_validate_allowlist_recipes || return 1
  agent_lab_publish_validated_allowlist
}
