#!/usr/bin/env bash
# Sourced, not executed. Starts Squid with the exact content-addressed policy requested by
# scripts/agent and verifies the active container label before any agent is launched.

agent_lab_egress_container_id() {
  local container_id
  container_id="$(
    run_compose --profile core --profile egress ps -q egress-proxy
  )" || return 1
  [ -n "$container_id" ] || return 1
  printf '%s\n' "$container_id"
}

agent_lab_active_egress_policy_hash() {
  local container_id
  container_id="$(agent_lab_egress_container_id)" || return 1
  docker inspect \
    --format '{{index .Config.Labels "org.agent-lab.egress-policy-sha256"}}' \
    "$container_id"
}

agent_lab_mounted_egress_policy_hash() {
  local container_id
  container_id="$(agent_lab_egress_container_id)" || return 1
  docker exec "$container_id" sha256sum /etc/squid/allowlist.txt | awk '{print $1}'
}

agent_lab_start_verified_egress() {
  local requested active mounted
  local recreate_proxy=0
  requested="${AGENT_LAB_EGRESS_POLICY_SHA256:?egress policy hash is not set}"
  active=""
  active="$(agent_lab_active_egress_policy_hash 2>/dev/null)" || true

  if [ -n "$active" ] && [ "$active" != "$requested" ]; then
    printf 'Replacing egress proxy policy sha256=%s with sha256=%s\n' "$active" "$requested"
    recreate_proxy=1
  fi

  if [ "$recreate_proxy" -eq 1 ]; then
    run_compose --profile core --profile egress up -d --wait dns
    run_compose --profile core --profile egress up -d --wait \
      --force-recreate egress-proxy
  else
    run_compose --profile core --profile egress up -d --wait dns egress-proxy
  fi

  active="$(agent_lab_active_egress_policy_hash 2>/dev/null)" || {
    printf 'FAIL cannot verify active egress policy container\n' >&2
    return 1
  }
  if [ "$active" != "$requested" ]; then
    printf 'FAIL active egress policy mismatch: requested=%s active=%s\n' \
      "$requested" "$active" >&2
    return 1
  fi
  mounted="$(agent_lab_mounted_egress_policy_hash 2>/dev/null)" || {
    printf 'FAIL cannot hash the policy mounted into the egress proxy\n' >&2
    return 1
  }
  if [ "$mounted" != "$requested" ]; then
    printf 'FAIL mounted egress policy mismatch: requested=%s mounted=%s\n' \
      "$requested" "$mounted" >&2
    return 1
  fi
  printf 'PASS active egress policy label and mounted bytes verified sha256=%s\n' "$active"
}
