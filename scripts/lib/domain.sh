#!/usr/bin/env bash
# Sourced, not executed. One canonical validator for DNS names used by configuration
# and allowlist recipe validation.

_agent_lab_domain_valid_body() {
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

agent_lab_domain_valid() {
  local LC_ALL=C
  local nocasematch_was_set=0 status
  shopt -q nocasematch && nocasematch_was_set=1
  shopt -u nocasematch
  if _agent_lab_domain_valid_body "$1"; then
    status=0
  else
    status=$?
  fi
  [ "$nocasematch_was_set" -eq 0 ] || shopt -s nocasematch
  return "$status"
}
