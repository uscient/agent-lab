#!/usr/bin/env bash
# Sourced, not executed. Validates the one documented external DNS result: an
# authoritative NXDOMAIN response containing zero answers.

agent_lab_dns_result_is_nxdomain() {
  local result="$1"
  printf '%s\n' "$result" | grep -Eq 'status:[[:space:]]*NXDOMAIN,' &&
    printf '%s\n' "$result" |
      grep -Eq 'QUERY:[[:space:]]*1,[[:space:]]*ANSWER:[[:space:]]*0,'
}
