#!/usr/bin/env bash
set -euo pipefail

test_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$test_dir/lib.sh"
source "$DOCKER_TEST_ROOT/scripts/lib/dns.sh"

trap docker_test_cleanup EXIT
docker_test_init "dns" || exit $?

failures=0
attempt=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

if ! docker_test_agent "base" true >/dev/null; then
  docker_test_infra "could not start DNS fixture substrate"
  exit 125
fi

probe="${LAB_PROJECT}-dns-probe"
docker_test_compose --profile devtools run -d --name "$probe" --no-deps \
  --entrypoint sleep egress-test infinity >/dev/null
docker_test_track_container "$probe"

configured_dns="$(docker inspect "$probe" | jq -r '.[0].HostConfig.Dns[]')"
if [ "$configured_dns" = "$LAB_DNS_IP" ]; then
  pass "container HostConfig.Dns points only at lab CoreDNS"
else
  fail "container HostConfig.Dns points only at lab CoreDNS"
fi
if docker exec "$probe" cat /etc/resolv.conf | grep -Eq \
     "^nameserver (${LAB_DNS_IP//./\\.}|127\\.0\\.0\\.11)$"; then
  pass "effective resolver file uses the configured Docker/CoreDNS path"
else
  fail "effective resolver file uses the configured Docker/CoreDNS path"
fi

internal_dns="$(
  docker exec "$probe" dig +short "@${LAB_DNS_IP}" dns.agent-lab.local A |
    grep -Ev '^$' || true
)"
internal_proxy="$(
  docker exec "$probe" dig +short "@${LAB_DNS_IP}" egress-proxy.agent-lab.local A |
    grep -Ev '^$' || true
)"
if [ "$internal_dns" = "$LAB_DNS_IP" ] && [ "$internal_proxy" = "$LAB_PROXY_IP" ]; then
  pass "exact internal A records resolve to their configured addresses"
else
  fail "exact internal A records resolve to their configured addresses"
fi

assert_nxdomain() {
  local name="$1"
  shift
  local output
  output="$(docker exec "$probe" dig +comments +noquestion +time=2 +tries=1 "$@" 2>&1)" ||
    true
  if agent_lab_dns_result_is_nxdomain "$output"; then
    pass "$name"
  else
    fail "$name"
  fi
}

external_name="${LAB_MARKER}.external.fixture.test"
assert_nxdomain "CoreDNS returns exact NXDOMAIN for external A over UDP" \
  "@${LAB_DNS_IP}" "$external_name" A
assert_nxdomain "CoreDNS returns exact NXDOMAIN for external AAAA over UDP" \
  "@${LAB_DNS_IP}" "$external_name" AAAA
assert_nxdomain "CoreDNS returns exact NXDOMAIN for external A over TCP" \
  +tcp "@${LAB_DNS_IP}" "$external_name" A
assert_nxdomain "CoreDNS returns exact NXDOMAIN for external AAAA over TCP" \
  +tcp "@${LAB_DNS_IP}" "$external_name" AAAA
assert_nxdomain "Docker embedded resolver preserves exact NXDOMAIN" \
  @127.0.0.11 "$external_name" A
assert_nxdomain "default resolver preserves exact NXDOMAIN" \
  "$external_name" AAAA

authority="${LAB_PROJECT}-external-dns"
authority_ip="198.18.${LAB_HTTP_CANARY_IP#198.18.}"
authority_ip="${authority_ip%.*}.53"
authority_corefile="$LAB_WORK/external.Corefile"
{
  printf '.:53 {\n'
  printf '    hosts {\n'
  printf '        %s external.fixture.test\n' "$LAB_HTTP_CANARY_IP"
  printf '        2001:db8::53 external.fixture.test\n'
  printf '    }\n'
  printf '}\n'
} > "$authority_corefile"
docker run -d \
  --name "$authority" \
  --network "${LAB_PROJECT}_egress" \
  --ip "$authority_ip" \
  --read-only \
  -v "$authority_corefile:/etc/coredns/Corefile:ro" \
  "$LAB_DNS_IMAGE_ID" -conf /etc/coredns/Corefile >/dev/null
docker_test_track_container "$authority"

authority_a=""
while [ "$attempt" -lt 30 ]; do
  authority_a="$(
    docker run --rm --network "${LAB_PROJECT}_egress" --entrypoint dig \
      "$LAB_EGRESS_TEST_IMAGE_ID" +short +time=1 +tries=1 \
      "@${authority_ip}" external.fixture.test A |
      grep -Ev '^$' || true
  )"
  [ "$authority_a" = "$LAB_HTTP_CANARY_IP" ] && break
  sleep 1
  attempt=$((attempt + 1))
done
authority_aaaa="$(
  docker run --rm --network "${LAB_PROJECT}_egress" --entrypoint dig \
    "$LAB_EGRESS_TEST_IMAGE_ID" +short "@${authority_ip}" external.fixture.test AAAA |
    grep -Ev '^$' || true
)"
if [ "$authority_a" = "$LAB_HTTP_CANARY_IP" ] &&
   [ "$authority_aaaa" = "2001:db8::53" ]; then
  pass "external A and AAAA authority positive control is healthy"
else
  docker_test_infra "external DNS authority did not become healthy"
  exit 125
fi

direct_dns_out=""
if direct_dns_out="$(
     docker exec "$probe" dig +short +time=1 +tries=1 \
       "@${authority_ip}" external.fixture.test A 2>&1
   )" &&
   [ "$direct_dns_out" = "$LAB_HTTP_CANARY_IP" ]; then
  fail "agent-side probe cannot query the external DNS authority directly"
else
  pass "agent-side probe cannot query the known-live external DNS authority directly"
fi

dns_id="$(docker_test_compose --profile core ps -q dns)"
docker stop "$dns_id" >/dev/null
stopped_name="${LAB_MARKER}.stopped.external.fixture.test"
stopped_out="$(
  docker exec "$probe" dig +comments +time=1 +tries=1 "$stopped_name" A 2>&1 || true
)"
if ! printf '%s\n' "$stopped_out" | grep -Fq "$LAB_HTTP_CANARY_IP" &&
   ! printf '%s\n' "$stopped_out" | grep -Eq 'ANSWER:[[:space:]]*[1-9]'; then
  pass "stopped CoreDNS has no fallback answer path"
else
  fail "stopped CoreDNS has no fallback answer path"
fi
docker start "$dns_id" >/dev/null
attempt=0
restored=""
while [ "$attempt" -lt 30 ]; do
  restored="$(
    docker exec "$probe" dig +short +time=1 +tries=1 \
      "@${LAB_DNS_IP}" dns.agent-lab.local A 2>/dev/null || true
  )"
  [ "$restored" = "$LAB_DNS_IP" ] && break
  sleep 1
  attempt=$((attempt + 1))
done
if [ "$restored" = "$LAB_DNS_IP" ]; then
  pass "CoreDNS restores its exact internal record after restart"
else
  docker_test_infra "CoreDNS did not recover after stopped-resolver check"
  exit 125
fi

if [ "$(
  docker network inspect "${LAB_PROJECT}_agents" --format '{{.EnableIPv6}}'
)" = "false" ] &&
   [ -z "$(
     docker inspect "$probe" |
       jq -r '.[0].NetworkSettings.Networks[].GlobalIPv6Address // empty'
   )" ]; then
  pass "agent network and probe have no IPv6 address path"
else
  fail "agent network and probe have no IPv6 address path"
fi

dns_logs="$(docker logs "$dns_id" 2>&1 || true)"
if printf '%s\n' "$dns_logs" | grep -Fq "$external_name"; then
  pass "CoreDNS logs contain the exact external query evidence"
else
  fail "CoreDNS logs contain the exact external query evidence"
fi

printf 'SUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
