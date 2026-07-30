#!/usr/bin/env bash
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/lib.sh"

docker_test_init "network" || exit $?
trap docker_test_cleanup EXIT

failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

if ! docker_test_agent "base" true >/dev/null; then
  docker_test_infra "could not start the isolated agent substrate"
  exit 125
fi

gateway_mode="$(
  docker network inspect "${LAB_PROJECT}_agents" \
    --format '{{index .Options "com.docker.network.bridge.gateway_mode_ipv4"}}'
)"
if [ "$gateway_mode" = "isolated" ]; then
  pass "agent bridge uses isolated IPv4 gateway mode"
else
  fail "agent bridge uses isolated IPv4 gateway mode"
fi

docker_test_start_http_canary || exit $?
if docker exec "$LAB_EGRESS_CONTROL" \
     curl -fsS --noproxy '*' "http://${LAB_HTTP_CANARY_IP}/${LAB_MARKER}" |
     grep -Fxq "$LAB_MARKER"; then
  pass "internet-side HTTP canary positive control is healthy"
else
  docker_test_infra "internet-side HTTP canary positive control failed"
  exit 125
fi

docker_test_start_udp_canary || exit $?
if docker exec "$LAB_EGRESS_CONTROL" python3 -c \
  'import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(2)
s.sendto(sys.argv[2].encode(), (sys.argv[1], 5353))
data, _ = s.recvfrom(4096)
raise SystemExit(0 if data.decode() == sys.argv[2] else 1)' \
  "$LAB_UDP_CANARY_IP" "$LAB_MARKER"; then
  pass "internet-side UDP canary positive control is healthy"
else
  docker_test_infra "internet-side UDP canary positive control failed"
  exit 125
fi

direct_out=""
if direct_out="$(docker_test_agent "base" bash -c \
     "if curl -fsS --noproxy '*' --connect-timeout 2 --max-time 4 \
       'http://${LAB_HTTP_CANARY_IP}/${LAB_MARKER}' >/dev/null 2>&1; then
        exit 42
      fi
      printf 'DIRECT_BLOCKED\n'")" &&
   printf '%s\n' "$direct_out" | grep -Fq "DIRECT_BLOCKED"; then
  pass "real agent cannot directly reach the known-live internet-side canary"
else
  fail "real agent cannot directly reach the known-live internet-side canary"
fi

udp_out=""
if udp_out="$(docker_test_agent "base" python3 -c \
  'import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(2)
try:
    s.sendto(sys.argv[2].encode(), (sys.argv[1], 5353))
    s.recvfrom(4096)
except (OSError, TimeoutError):
    print("UDP_BLOCKED")
    raise SystemExit(0)
raise SystemExit(42)' \
  "$LAB_UDP_CANARY_IP" "$LAB_MARKER")" &&
  printf '%s\n' "$udp_out" | grep -Fq "UDP_BLOCKED"; then
  pass "real agent cannot directly reach the known-live UDP canary"
else
  fail "real agent cannot directly reach the known-live UDP canary"
fi

if ! docker_test_compose --profile devtools build egress-test >/dev/null; then
  docker_test_infra "could not build the controlled egress-test image"
  exit 125
fi
egress_test_out=""
if egress_test_out="$(
     docker_test_compose --profile devtools run --rm --no-deps --entrypoint /bin/bash \
       egress-test -c \
       "if curl -fsS --noproxy '*' --connect-timeout 2 --max-time 4 \
         'http://${LAB_HTTP_CANARY_IP}/${LAB_MARKER}' >/dev/null 2>&1; then
          exit 42
        fi
        printf 'DIRECT_BLOCKED\n'"
   )" &&
   printf '%s\n' "$egress_test_out" | grep -Fq "DIRECT_BLOCKED"; then
  pass "egress-test cannot directly reach the known-live internet-side canary"
else
  fail "egress-test cannot directly reach the known-live internet-side canary"
fi

allow_token="${LAB_MARKER}-allow"
if docker_test_agent "base,node-dev" bash -c \
     "test \"\$(curl -fsS --proxy 'http://${LAB_PROXY_IP}:3128' \
       'http://registry.npmjs.org/${allow_token}')\" = '${allow_token}'"; then
  pass "allowed proxy path reaches the controlled canary with exact content"
else
  fail "allowed proxy path reaches the controlled canary with exact content"
fi
proxy_id="$(docker_test_proxy_container)"
if docker exec "$proxy_id" grep -F "$allow_token" /var/log/squid/access.log |
     grep -Fq "TCP_MISS/200"; then
  pass "allowed proxy request has matching TCP_MISS/200 audit evidence"
else
  fail "allowed proxy request has matching TCP_MISS/200 audit evidence"
fi

deny_token="${LAB_MARKER}-deny"
if docker_test_agent "base" bash -c \
     "code=\$(curl -sS --proxy 'http://${LAB_PROXY_IP}:3128' \
       --output /dev/null --write-out '%{http_code}' \
       'http://registry.npmjs.org/${deny_token}'); test \"\$code\" = 403"; then
  pass "downgraded policy returns an exact proxy denial"
else
  fail "downgraded policy returns an exact proxy denial"
fi
proxy_id="$(docker_test_proxy_container)"
if docker exec "$proxy_id" grep -F "$deny_token" /var/log/squid/access.log |
     grep -Fq "TCP_DENIED/403"; then
  pass "denied proxy request has matching TCP_DENIED/403 audit evidence"
else
  fail "denied proxy request has matching TCP_DENIED/403 audit evidence"
fi

# Sensitivity control: the same probe succeeds from a workload deliberately attached to
# the internet-side fixture network, proving that target health and probe logic are sound.
if docker run --rm \
     --network "${LAB_PROJECT}_egress" \
     --entrypoint curl \
     agent-lab/devbox:local \
     -fsS --noproxy '*' "http://${LAB_HTTP_CANARY_IP}/${LAB_MARKER}" |
     grep -Fxq "$LAB_MARKER"; then
  pass "insecure egress-network mutation turns the direct probe red"
else
  docker_test_infra "sensitivity control could not reach the canary"
  exit 125
fi

proxy_id="$(docker_test_proxy_container)"
docker stop "$proxy_id" >/dev/null
proxy_rc=0
docker_test_require_running_proxy || proxy_rc=$?
if [ "$proxy_rc" -eq 125 ]; then
  pass "dead proxy is classified as infrastructure failure"
else
  fail "dead proxy is classified as infrastructure failure"
fi

printf 'SUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
