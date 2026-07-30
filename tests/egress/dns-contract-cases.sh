#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
contract="$repo_root/scripts/lib/dns.sh"
failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

if [ -f "$contract" ]; then
  # shellcheck source=/dev/null
  source "$contract"
else
  fail "exact DNS result parser exists"
fi

check_result() {
  local expected="$1" name="$2" fixture="$3" rc=0
  if declare -F agent_lab_dns_result_is_nxdomain >/dev/null 2>&1; then
    agent_lab_dns_result_is_nxdomain "$fixture" || rc=$?
  else
    rc=127
  fi
  if { [ "$expected" = pass ] && [ "$rc" -eq 0 ]; } ||
     { [ "$expected" = fail ] && [ "$rc" -ne 0 ]; }; then
    pass "$name"
  else
    fail "$name"
  fi
}

coredns_server_block() {
  local zone="$1" corefile="$2"
  awk -v target="$zone" '
    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      sub(/[[:space:]]*$/, "", line)
      if (!capture && depth == 0 && line == target " {") {
        capture = 1
        found = 1
      }
      if (capture) {
        print
      }

      braces = $0
      sub(/#.*/, "", braces)
      opening = gsub(/\{/, "", braces)
      braces = $0
      sub(/#.*/, "", braces)
      closing = gsub(/\}/, "", braces)
      depth += opening - closing

      if (capture && depth == 0) {
        exit
      }
    }
    END {
      if (!found) {
        exit 1
      }
    }
  ' "$corefile"
}

exact_nxdomain=';; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN, id: 1
;; flags: qr aa rd; QUERY: 1, ANSWER: 0, AUTHORITY: 0, ADDITIONAL: 0'
servfail=';; ->>HEADER<<- opcode: QUERY, status: SERVFAIL, id: 2
;; flags: qr rd; QUERY: 1, ANSWER: 0, AUTHORITY: 0, ADDITIONAL: 0'
refused=';; ->>HEADER<<- opcode: QUERY, status: REFUSED, id: 3
;; flags: qr; QUERY: 1, ANSWER: 0, AUTHORITY: 0, ADDITIONAL: 0'
nxdomain_with_answer=';; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN, id: 4
;; flags: qr aa; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 0'

check_result pass "exact authoritative NXDOMAIN with zero answers is accepted" "$exact_nxdomain"
check_result fail "SERVFAIL is never accepted as policy evidence" "$servfail"
check_result fail "REFUSED is not the documented policy result" "$refused"
check_result fail "NXDOMAIN with an answer is rejected" "$nxdomain_with_answer"

if grep -Fq 'status: SERVFAIL' "$repo_root/tests/egress/cases.sh"; then
  fail "blocking egress checks do not accept generic SERVFAIL"
else
  pass "blocking egress checks do not accept generic SERVFAIL"
fi

corefile="$repo_root/dns/coredns/Corefile"
internal_block="$(coredns_server_block agent-lab.local:53 "$corefile" || true)"
external_block="$(coredns_server_block .:53 "$corefile" || true)"
if [ "$(grep -Fxc 'agent-lab.local:53 {' "$corefile")" -eq 1 ] &&
   [ "$(grep -Fxc '.:53 {' "$corefile")" -eq 1 ] &&
   printf '%s\n' "$internal_block" | grep -Fq '    hosts {' &&
   printf '%s\n' "$internal_block" |
     grep -Fq '        172.30.0.10 dns.agent-lab.local' &&
   printf '%s\n' "$internal_block" |
     grep -Fq '        172.30.0.20 egress-proxy.agent-lab.local' &&
   ! printf '%s\n' "$internal_block" | grep -Fq 'template IN' &&
   [ "$(printf '%s\n' "$external_block" | grep -Fxc '    template IN A {')" -eq 1 ] &&
   [ "$(printf '%s\n' "$external_block" | grep -Fxc '    template IN AAAA {')" -eq 1 ] &&
   [ "$(printf '%s\n' "$external_block" |
     grep -Fxc '        rcode NXDOMAIN')" -eq 2 ] &&
   ! printf '%s\n' "$external_block" | grep -Fq '    hosts {' &&
   ! grep -Eq '^[[:space:]]*(fallthrough|forward)([[:space:]]|$)' "$corefile"; then
  pass "CoreDNS isolates internal records from catch-all NXDOMAIN templates"
else
  fail "CoreDNS isolates internal records from catch-all NXDOMAIN templates"
fi

if [ -f "$repo_root/tests/security/docker.manifest" ] &&
   grep -Fq 'suite dns-contract tests/docker/dns-contract.sh' \
     "$repo_root/tests/security/docker.manifest"; then
  pass "Docker gate requires exact resolver-path coverage"
else
  fail "Docker gate requires exact resolver-path coverage"
fi

printf 'SUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
