#!/usr/bin/env bash
# Sourced, not executed. Starts Squid with the exact content-addressed policy requested by
# scripts/agent and verifies the active container label before any agent is launched.

agent_lab_active_egress_policy_hash() {
  local container_id
  container_id="$(
    run_compose --profile core --profile egress ps -q egress-proxy
  )" || return 1
  [ -n "$container_id" ] || return 1
  docker inspect \
    --format '{{index .Config.Labels "org.agent-lab.egress-policy-sha256"}}' \
    "$container_id"
}

agent_lab_start_verified_egress() {
  local requested active
  local -a recreate_args=()
  requested="${AGENT_LAB_EGRESS_POLICY_SHA256:?egress policy hash is not set}"
  active=""
  active="$(agent_lab_active_egress_policy_hash 2>/dev/null)" || true

  if [ -n "$active" ] && [ "$active" != "$requested" ]; then
    printf 'Replacing egress proxy policy sha256=%s with sha256=%s\n' "$active" "$requested"
    recreate_args=(--force-recreate)
  fi

  run_compose --profile core --profile egress up -d --wait \
    "${recreate_args[@]}" dns egress-proxy

  active="$(agent_lab_active_egress_policy_hash 2>/dev/null)" || {
    printf 'FAIL cannot verify active egress policy container\n' >&2
    return 1
  }
  if [ "$active" != "$requested" ]; then
    printf 'FAIL active egress policy mismatch: requested=%s active=%s\n' \
      "$requested" "$active" >&2
    return 1
  fi
  printf 'PASS active egress policy verified sha256=%s\n' "$active"
}
