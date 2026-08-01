#!/usr/bin/env bash
# Sourced, not executed. Single source of configuration authority for scripts/agent.
#
# The env file is parsed as data and is never sourced. Every supported value is resolved
# with exact precedence (shell environment > env file > documented default), validated,
# and exported before Compose can consume it. Unsupported or ambiguous env-file syntax is
# rejected instead of being interpreted differently by this script and Docker Compose.

# shellcheck source=scripts/lib/domain.sh
agent_lab_domain_lib_dir="${BASH_SOURCE[0]}"
case "$agent_lab_domain_lib_dir" in
  */*) agent_lab_domain_lib_dir="${agent_lab_domain_lib_dir%/*}" ;;
  *) agent_lab_domain_lib_dir=. ;;
esac
source "$agent_lab_domain_lib_dir/domain.sh" || return 1
unset agent_lab_domain_lib_dir

AGENT_LAB_CONFIG_KEYS=(
  AGENT_LAB_AGENTS_SUBNET
  AGENT_LAB_EGRESS_SUBNET
  AGENT_LAB_DNS_IP
  AGENT_LAB_PROXY_IP
  AGENT_LAB_PROXY_PORT
  HTTP_PROXY
  HTTPS_PROXY
  NO_PROXY
  AGENT_LAB_ALLOWED_TEST_DOMAIN
  AGENT_LAB_DIRECT_TEST_IP
  AGENT_LAB_EGRESS_ALLOWLIST
  AGENT_LAB_AGENT_IMAGE
  AGENT_LAB_PROJECT_DIR
  AGENT_LAB_SECRETS_DIR
  AGENT_LAB_EPHEMERAL_HOME
  AGENT_LAB_ALLOWLIST_RECIPES
  AGENT_LAB_AGENT_UID
  AGENT_LAB_AGENT_GID
  AGENT_LAB_AGENT_MEM
  AGENT_LAB_AGENT_CPUS
)

AGENT_LAB_PARSED_KEYS=()
AGENT_LAB_PARSED_VALUES=()
AGENT_LAB_PARSED_VALUE=""

agent_lab_config_key_supported() {
  local wanted key
  wanted="$1"
  for key in "${AGENT_LAB_CONFIG_KEYS[@]}"; do
    [ "$key" = "$wanted" ] && return 0
  done
  return 1
}

agent_lab_config_default() {
  case "$1" in
    AGENT_LAB_AGENTS_SUBNET)      printf '172.30.0.0/24' ;;
    AGENT_LAB_EGRESS_SUBNET)      printf '198.18.0.0/24' ;;
    AGENT_LAB_DNS_IP)             printf '172.30.0.10' ;;
    AGENT_LAB_PROXY_IP)           printf '172.30.0.20' ;;
    AGENT_LAB_PROXY_PORT)         printf '3128' ;;
    HTTP_PROXY|HTTPS_PROXY)
      printf 'http://%s:%s' "${AGENT_LAB_PROXY_IP:-172.30.0.20}" \
        "${AGENT_LAB_PROXY_PORT:-3128}"
      ;;
    NO_PROXY)
      printf 'localhost,127.0.0.1,::1,%s' \
        "${AGENT_LAB_AGENTS_SUBNET:-172.30.0.0/24}"
      ;;
    AGENT_LAB_ALLOWED_TEST_DOMAIN) printf 'example.com' ;;
    AGENT_LAB_DIRECT_TEST_IP)      printf '1.1.1.1' ;;
    AGENT_LAB_EGRESS_ALLOWLIST)    printf '' ;;
    AGENT_LAB_AGENT_IMAGE)         printf 'agent-lab/devbox:local' ;;
    AGENT_LAB_PROJECT_DIR)         printf '' ;;
    AGENT_LAB_SECRETS_DIR)         printf './secrets' ;;
    AGENT_LAB_EPHEMERAL_HOME)      printf '0' ;;
    AGENT_LAB_ALLOWLIST_RECIPES)   printf 'base' ;;
    AGENT_LAB_AGENT_UID)           printf '1000' ;;
    AGENT_LAB_AGENT_GID)           printf '1000' ;;
    AGENT_LAB_AGENT_MEM)           printf '4g' ;;
    AGENT_LAB_AGENT_CPUS)          printf '2' ;;
    *) return 1 ;;
  esac
}

agent_lab_envfile_value_syntax() {
  local key value file line_no
  key="$1"
  value="$2"
  file="$3"
  line_no="$4"

  case "$value" in
    *$'\r'*)
      printf 'FAIL carriage return in %s at %s:%s\n' "$key" "$file" "$line_no" >&2
      return 1
      ;;
    *\"*|*\'*)
      printf 'FAIL %s at %s:%s contains quotes; use an exact unquoted value\n' \
        "$key" "$file" "$line_no" >&2
      return 1
      ;;
    *'$'*|*'`'*|*';'*|*'&'*|*'|'*|*'<'*|*'>'*|*'('*|*')'*|*\\*)
      printf 'FAIL %s at %s:%s contains shell metacharacters; refusing\n' \
        "$key" "$file" "$line_no" >&2
      return 1
      ;;
    *'#'*)
      printf 'FAIL %s at %s:%s contains an inline comment\n' \
        "$key" "$file" "$line_no" >&2
      return 1
      ;;
    *[[:space:]]*)
      printf 'FAIL %s at %s:%s contains whitespace; quoting is not supported\n' \
        "$key" "$file" "$line_no" >&2
      return 1
      ;;
  esac
  return 0
}

# Parse the entire env file once. Blank lines and comments beginning in column one are
# allowed. Assignments are exact KEY=VALUE records; duplicates and unsupported keys fail.
# The read loop explicitly accepts a final assignment without a trailing newline.
agent_lab_parse_env_file() {
  local file line key value existing line_no
  file="$1"
  AGENT_LAB_PARSED_KEYS=()
  AGENT_LAB_PARSED_VALUES=()
  line_no=0

  [ -f "$file" ] || {
    printf 'FAIL env file is missing or not a regular file: %s\n' "$file" >&2
    return 1
  }
  if ! cmp -s "$file" <(LC_ALL=C tr -d '\000' < "$file"); then
    printf 'FAIL NUL byte in env file: %s\n' "$file" >&2
    return 1
  fi

  # shellcheck disable=SC2094 # parser and its diagnostic helper never write $file.
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    case "$line" in
      *$'\r'*)
        printf 'FAIL carriage return in env-file assignment at %s:%s\n' \
          "$file" "$line_no" >&2
        return 1
        ;;
    esac
    case "$line" in
      ''|'#'*) continue ;;
      *=*) ;;
      *)
        printf 'FAIL malformed env-file assignment at %s:%s\n' "$file" "$line_no" >&2
        return 1
        ;;
    esac

    key="${line%%=*}"
    value="${line#*=}"
    case "$key" in
      ''|[0-9]*|*[!A-Za-z0-9_]*)
        printf 'FAIL malformed env-file assignment at %s:%s\n' "$file" "$line_no" >&2
        return 1
        ;;
    esac
    if ! agent_lab_config_key_supported "$key"; then
      printf 'FAIL unsupported env-file key at %s:%s: %s\n' "$file" "$line_no" "$key" >&2
      return 1
    fi
    if [ "${#AGENT_LAB_PARSED_KEYS[@]}" -gt 0 ]; then
      for existing in "${AGENT_LAB_PARSED_KEYS[@]}"; do
        if [ "$existing" = "$key" ]; then
          printf 'FAIL duplicate env-file assignment at %s:%s: %s\n' \
            "$file" "$line_no" "$key" >&2
          return 1
        fi
      done
    fi
    agent_lab_envfile_value_syntax "$key" "$value" "$file" "$line_no" || return 1
    AGENT_LAB_PARSED_KEYS+=("$key")
    AGENT_LAB_PARSED_VALUES+=("$value")
  done < "$file"
}

agent_lab_parsed_envfile_value() {
  local wanted i
  wanted="$1"
  AGENT_LAB_PARSED_VALUE=""
  if [ "${#AGENT_LAB_PARSED_KEYS[@]}" -gt 0 ]; then
    for i in "${!AGENT_LAB_PARSED_KEYS[@]}"; do
      if [ "${AGENT_LAB_PARSED_KEYS[$i]}" = "$wanted" ]; then
        AGENT_LAB_PARSED_VALUE="${AGENT_LAB_PARSED_VALUES[$i]}"
        return 0
      fi
    done
  fi
  return 1
}

# Compute and export every supported value. Shell values, including explicitly empty
# values, take precedence and are validated later rather than silently defaulted.
agent_lab_load_byoa_config() {
  local LC_ALL=C
  local file key value
  file="$1"
  agent_lab_parse_env_file "$file" || return 1

  for key in "${AGENT_LAB_CONFIG_KEYS[@]}"; do
    if [ -n "${!key+x}" ]; then
      value="${!key}"
    elif agent_lab_parsed_envfile_value "$key"; then
      value="$AGENT_LAB_PARSED_VALUE"
    else
      value="$(agent_lab_config_default "$key")" || return 1
    fi
    printf -v "$key" '%s' "$value"
    # shellcheck disable=SC2163 # export the variable named by $key.
    export "$key"
  done
}

agent_lab_validate_boolean() {
  case "${AGENT_LAB_EPHEMERAL_HOME}" in
    0|1) return 0 ;;
    *)
      printf 'FAIL AGENT_LAB_EPHEMERAL_HOME must be exactly 0 or 1\n' >&2
      return 1
      ;;
  esac
}

agent_lab_validate_id_value() {
  local key value max
  key="$1"
  value="$2"
  max=2147483647
  case "$value" in
    ''|0|0*|*[!0-9]*)
      printf 'FAIL %s must be a canonical positive decimal integer\n' "$key" >&2
      return 1
      ;;
  esac
  if [ "${#value}" -gt "${#max}" ] ||
     { [ "${#value}" -eq "${#max}" ] && [ "$value" -gt "$max" ]; }; then
    printf 'FAIL %s exceeds the supported maximum %s\n' "$key" "$max" >&2
    return 1
  fi
  return 0
}

agent_lab_validate_uid_gid() {
  agent_lab_validate_id_value AGENT_LAB_AGENT_UID "${AGENT_LAB_AGENT_UID}" || return 1
  agent_lab_validate_id_value AGENT_LAB_AGENT_GID "${AGENT_LAB_AGENT_GID}" || return 1
  printf 'PASS agent runs as canonical non-root %s:%s\n' \
    "${AGENT_LAB_AGENT_UID}" "${AGENT_LAB_AGENT_GID}"
}

agent_lab_validate_memory() {
  local value amount unit max
  value="${AGENT_LAB_AGENT_MEM}"
  if [[ ! "$value" =~ ^([1-9][0-9]*)([mg])$ ]]; then
    printf 'FAIL AGENT_LAB_AGENT_MEM must be an integer with lowercase m or g\n' >&2
    return 1
  fi
  amount="${BASH_REMATCH[1]}"
  unit="${BASH_REMATCH[2]}"
  if [ "$unit" = m ]; then
    max=65536
    if [ "${#amount}" -gt "${#max}" ] ||
       { [ "${#amount}" -eq "${#max}" ] && [ "$amount" -gt "$max" ]; } ||
       [ "$amount" -lt 64 ]; then
      printf 'FAIL AGENT_LAB_AGENT_MEM must be between 64m and 65536m\n' >&2
      return 1
    fi
  else
    max=64
    if [ "${#amount}" -gt "${#max}" ] ||
       { [ "${#amount}" -eq "${#max}" ] && [ "$amount" -gt "$max" ]; }; then
      printf 'FAIL AGENT_LAB_AGENT_MEM must be between 1g and 64g\n' >&2
      return 1
    fi
  fi
  return 0
}

agent_lab_validate_cpus() {
  local value whole fraction
  value="${AGENT_LAB_AGENT_CPUS}"
  if [[ ! "$value" =~ ^(0\.([1-9]|[1-9][0-9]?[1-9])|[1-9][0-9]?(\.[0-9]{0,2}[1-9])?)$ ]]; then
    printf 'FAIL AGENT_LAB_AGENT_CPUS must be a canonical number from 0.1 through 64\n' >&2
    return 1
  fi
  whole="${value%%.*}"
  if [ "$whole" -gt 64 ]; then
    printf 'FAIL AGENT_LAB_AGENT_CPUS must not exceed 64\n' >&2
    return 1
  fi
  if [ "$whole" -eq 64 ] && [ "$value" != 64 ]; then
    fraction="${value#*.}"
    printf 'FAIL AGENT_LAB_AGENT_CPUS must not exceed 64 (fraction %s)\n' "$fraction" >&2
    return 1
  fi
  return 0
}

agent_lab_validate_ipv4() {
  local value a b c d extra octet
  value="$1"
  case "$value" in
    *.) return 1 ;;
  esac
  IFS=. read -r a b c d extra <<< "$value"
  [ -z "${extra:-}" ] && [ -n "${a:-}" ] && [ -n "${b:-}" ] &&
    [ -n "${c:-}" ] && [ -n "${d:-}" ] || return 1
  for octet in "$a" "$b" "$c" "$d"; do
    case "$octet" in
      0|[1-9]|[1-9][0-9]|[1-9][0-9][0-9]) ;;
      *) return 1 ;;
    esac
    [ "$octet" -le 255 ] || return 1
  done
  return 0
}

agent_lab_validate_cidr24() {
  local value network
  value="$1"
  case "$value" in
    */24) network="${value%/24}" ;;
    *) return 1 ;;
  esac
  agent_lab_validate_ipv4 "$network" || return 1
  [ "${network##*.}" = 0 ]
}

agent_lab_validate_domain() {
  agent_lab_domain_valid "$1"
}

agent_lab_validate_topology() {
  local agents_network egress_network expected_proxy expected_no_proxy
  local direct_a direct_b _direct_c direct_d
  agent_lab_validate_cidr24 "${AGENT_LAB_AGENTS_SUBNET}" || {
    printf 'FAIL AGENT_LAB_AGENTS_SUBNET must be a canonical IPv4 /24 network\n' >&2
    return 1
  }
  agent_lab_validate_cidr24 "${AGENT_LAB_EGRESS_SUBNET}" || {
    printf 'FAIL AGENT_LAB_EGRESS_SUBNET must be a canonical IPv4 /24 network\n' >&2
    return 1
  }
  [ "${AGENT_LAB_AGENTS_SUBNET}" != "${AGENT_LAB_EGRESS_SUBNET}" ] || {
    printf 'FAIL agent and egress subnets must be distinct\n' >&2
    return 1
  }
  agent_lab_validate_ipv4 "${AGENT_LAB_DNS_IP}" || {
    printf 'FAIL AGENT_LAB_DNS_IP must be a canonical IPv4 address\n' >&2
    return 1
  }
  agent_lab_validate_ipv4 "${AGENT_LAB_PROXY_IP}" || {
    printf 'FAIL AGENT_LAB_PROXY_IP must be a canonical IPv4 address\n' >&2
    return 1
  }
  agents_network="${AGENT_LAB_AGENTS_SUBNET%.*}"
  [ "${AGENT_LAB_DNS_IP%.*}" = "$agents_network" ] &&
    [ "${AGENT_LAB_PROXY_IP%.*}" = "$agents_network" ] || {
      printf 'FAIL DNS and proxy IPs must be inside AGENT_LAB_AGENTS_SUBNET\n' >&2
      return 1
    }
  [ "${AGENT_LAB_DNS_IP}" != "${AGENT_LAB_PROXY_IP}" ] || {
    printf 'FAIL AGENT_LAB_DNS_IP and AGENT_LAB_PROXY_IP must be distinct\n' >&2
    return 1
  }
  case "${AGENT_LAB_DNS_IP##*.}:${AGENT_LAB_PROXY_IP##*.}" in
    0:*|255:*|*:0|*:255)
      printf 'FAIL DNS and proxy IPs must be usable host addresses\n' >&2
      return 1
      ;;
  esac
  [ "${AGENT_LAB_PROXY_PORT}" = 3128 ] || {
    printf 'FAIL AGENT_LAB_PROXY_PORT must be exactly 3128\n' >&2
    return 1
  }
  expected_proxy="http://${AGENT_LAB_PROXY_IP}:${AGENT_LAB_PROXY_PORT}"
  [ "${HTTP_PROXY}" = "$expected_proxy" ] && [ "${HTTPS_PROXY}" = "$expected_proxy" ] || {
    printf 'FAIL HTTP_PROXY and HTTPS_PROXY must name the validated lab proxy\n' >&2
    return 1
  }
  expected_no_proxy="localhost,127.0.0.1,::1,${AGENT_LAB_AGENTS_SUBNET}"
  [ "${NO_PROXY}" = "$expected_no_proxy" ] || {
    printf 'FAIL NO_PROXY must exactly match the validated agent subnet policy\n' >&2
    return 1
  }
  case "${AGENT_LAB_ALLOWED_TEST_DOMAIN}" in
    .*)
      printf 'FAIL AGENT_LAB_ALLOWED_TEST_DOMAIN must be a hostname, not a suffix\n' >&2
      return 1
      ;;
  esac
  agent_lab_validate_domain "${AGENT_LAB_ALLOWED_TEST_DOMAIN}" || {
    printf 'FAIL AGENT_LAB_ALLOWED_TEST_DOMAIN must be a canonical DNS name\n' >&2
    return 1
  }
  agent_lab_validate_ipv4 "${AGENT_LAB_DIRECT_TEST_IP}" || {
    printf 'FAIL AGENT_LAB_DIRECT_TEST_IP must be a canonical IPv4 address\n' >&2
    return 1
  }
  IFS=. read -r direct_a direct_b _direct_c direct_d <<< "${AGENT_LAB_DIRECT_TEST_IP}"
  if [ "$direct_a" -eq 0 ] || [ "$direct_a" -eq 127 ] ||
     [ "$direct_a" -ge 224 ] ||
     { [ "$direct_a" -eq 169 ] && [ "$direct_b" -eq 254 ]; } ||
     [ "$direct_d" -eq 0 ] || [ "$direct_d" -eq 255 ]; then
    printf 'FAIL AGENT_LAB_DIRECT_TEST_IP must be a usable non-local host address\n' >&2
    return 1
  fi
  egress_network="${AGENT_LAB_EGRESS_SUBNET%.*}"
  [ "${AGENT_LAB_DIRECT_TEST_IP%.*}" != "$agents_network" ] ||
    [ "${AGENT_LAB_DIRECT_TEST_IP%.*}" = "$egress_network" ] || {
      printf 'FAIL AGENT_LAB_DIRECT_TEST_IP must not target the agent subnet\n' >&2
      return 1
    }
  return 0
}

agent_lab_validate_image_ref() {
  local value name tag digest first port
  value="${AGENT_LAB_AGENT_IMAGE}"
  [ -n "$value" ] && [ "${#value}" -le 255 ] || {
    printf 'FAIL AGENT_LAB_AGENT_IMAGE must not be empty or overlong\n' >&2
    return 1
  }
  case "$value" in
    -*|*://*|/*|*/|*//*|*@*@*|*[!A-Za-z0-9._/:@-]*)
      printf 'FAIL AGENT_LAB_AGENT_IMAGE is not a safe Docker image reference\n' >&2
      return 1
      ;;
  esac

  name="$value"
  tag=""
  digest=""
  case "$name" in
    *@*)
      digest="${name#*@}"
      name="${name%%@*}"
      if [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] ||
         [[ "${name##*/}" == *:* ]]; then
        printf 'FAIL AGENT_LAB_AGENT_IMAGE has an invalid digest reference\n' >&2
        return 1
      fi
      ;;
    *)
      if [[ "${name##*/}" == *:* ]]; then
        tag="${name##*:}"
        name="${name%:*}"
        if [[ ! "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
          printf 'FAIL AGENT_LAB_AGENT_IMAGE has an invalid tag\n' >&2
          return 1
        fi
      fi
      ;;
  esac
  if [[ ! "$name" =~ ^([a-z0-9]+([.-][a-z0-9]+)*(:[1-9][0-9]{0,4})?/)?[a-z0-9]+([._-][a-z0-9]+)*(/[a-z0-9]+([._-][a-z0-9]+)*)*$ ]]; then
    printf 'FAIL AGENT_LAB_AGENT_IMAGE has an invalid repository name\n' >&2
    return 1
  fi
  first="${name%%/*}"
  if [[ "$first" == *:* ]]; then
    port="${first##*:}"
    [ "$port" -le 65535 ] || {
      printf 'FAIL AGENT_LAB_AGENT_IMAGE registry port is out of range\n' >&2
      return 1
    }
  fi
  return 0
}

agent_lab_validate_mount_value() {
  local key value
  key="$1"
  value="$2"
  case "$value" in
    *[[:cntrl:]]*)
      printf 'FAIL %s contains control characters\n' "$key" >&2
      return 1
      ;;
    *:*)
      printf 'FAIL %s contains a colon that is ambiguous in a Compose short mount\n' \
        "$key" >&2
      return 1
      ;;
  esac
  return 0
}

agent_lab_validate_project_name() {
  case "${PROJECT_NAME:-}" in
    ''|[!a-z0-9]*|*[!a-z0-9_-]*)
      printf 'FAIL COMPOSE_PROJECT_NAME must use lowercase letters, digits, dash, or underscore\n' >&2
      return 1
      ;;
  esac
}

agent_lab_validate_config() {
  local LC_ALL=C
  agent_lab_validate_boolean || return 1
  agent_lab_validate_uid_gid || return 1
  agent_lab_validate_memory || return 1
  agent_lab_validate_cpus || return 1
  agent_lab_validate_topology || return 1
  agent_lab_validate_image_ref || return 1
  agent_lab_validate_mount_value AGENT_LAB_PROJECT_DIR "${AGENT_LAB_PROJECT_DIR}" || return 1
  agent_lab_validate_mount_value AGENT_LAB_SECRETS_DIR "${AGENT_LAB_SECRETS_DIR}" || return 1
  [ -n "${AGENT_LAB_SECRETS_DIR}" ] || {
    printf 'FAIL AGENT_LAB_SECRETS_DIR must not be empty\n' >&2
    return 1
  }
  case "${AGENT_LAB_EGRESS_ALLOWLIST}" in
    ''|./policies/egress.allowlist.example)
      # The tracked example still carries the legacy direct-policy default for scripts/up.
      # scripts/agent never consumes it: recipes are the sole policy authority.
      AGENT_LAB_EGRESS_ALLOWLIST=""
      export AGENT_LAB_EGRESS_ALLOWLIST
      ;;
    *)
      printf 'FAIL AGENT_LAB_EGRESS_ALLOWLIST is managed by recipes and must be unset\n' >&2
      return 1
      ;;
  esac
  agent_lab_validate_project_name || return 1
  printf 'PASS configuration schema validated\n'
}
