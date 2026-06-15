#!/usr/bin/env bash
set -euo pipefail

mode="${1:-all}"
failures=0
not_implemented=0

allowed_domain="${AGENT_LAB_ALLOWED_TEST_DOMAIN:-example.com}"
direct_test_ip="${AGENT_LAB_DIRECT_TEST_IP:-1.1.1.1}"
dns_ip="${AGENT_LAB_DNS_IP:-172.30.0.10}"
proxy_url="${HTTPS_PROXY:-${HTTP_PROXY:-http://172.30.0.20:3128}}"

pass() {
  printf 'PASS %s\n' "$1"
}

fail() {
  printf 'FAIL %s\n' "$1"
  failures=$((failures + 1))
}

todo() {
  printf 'NOT_IMPLEMENTED %s\n' "$1"
  not_implemented=$((not_implemented + 1))
}

require_tool() {
  if command -v "$1" >/dev/null 2>&1; then
    pass "tool available: $1"
  else
    fail "required tool missing: $1"
  fi
}

expect_success() {
  local name="$1"
  shift
  if "$@"; then
    pass "$name"
  else
    fail "$name"
  fi
}

expect_failure() {
  local name="$1"
  shift
  if "$@"; then
    fail "$name"
  else
    pass "$name"
  fi
}

curl_base() {
  curl --silent --show-error --fail --location --connect-timeout 4 --max-time 10 "$@"
}

direct_public_curl() {
  HTTP_PROXY='' HTTPS_PROXY='' ALL_PROXY='' http_proxy='' https_proxy='' all_proxy='' NO_PROXY='*' \
    curl --silent --show-error --location --connect-timeout 4 --max-time 8 \
      --noproxy '*' "http://${direct_test_ip}/" >/tmp/direct-public.out 2>/tmp/direct-public.err
}

proxied_allowed_curl() {
  curl_base --proxy "$proxy_url" "https://${allowed_domain}/" >/tmp/proxied-allowed.out 2>/tmp/proxied-allowed.err
}

proxied_denied_domain_curl() {
  curl_base --proxy "$proxy_url" "https://iana.org/" >/tmp/proxied-denied-domain.out 2>/tmp/proxied-denied-domain.err
}

proxied_private_curl() {
  curl_base --proxy "$proxy_url" "http://10.0.0.1/" >/tmp/proxied-private.out 2>/tmp/proxied-private.err
}

proxied_lan_curl() {
  curl_base --proxy "$proxy_url" "http://192.168.0.1/" >/tmp/proxied-lan.out 2>/tmp/proxied-lan.err
}

proxied_metadata_curl() {
  curl_base --proxy "$proxy_url" "http://169.254.169.254/latest/meta-data/" >/tmp/proxied-metadata.out 2>/tmp/proxied-metadata.err
}

proxied_raw_ip_connect() {
  curl_base --proxy "$proxy_url" "https://${direct_test_ip}/" >/tmp/proxied-raw-ip.out 2>/tmp/proxied-raw-ip.err
}

coredns_external_refuses() {
  local out
  out="$(dig @"$dns_ip" +time=2 +tries=1 "$allowed_domain" A 2>&1 || true)"
  printf '%s\n' "$out" >/tmp/coredns-external.out
  case "$out" in
    *"status: REFUSED"*|*"status: NXDOMAIN"*|*"status: SERVFAIL"*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

direct_external_dns_query() {
  dig @1.1.1.1 +time=2 +tries=1 "$allowed_domain" A >/tmp/direct-dns.out 2>/tmp/direct-dns.err
}

docker_socket_absent() {
  test ! -e /var/run/docker.sock
}

root_filesystem_read_only() {
  ! touch /etc/agent-lab-rootfs-write-test >/tmp/rootfs-write.out 2>/tmp/rootfs-write.err
}

tmp_is_writable() {
  touch /tmp/agent-lab-tmp-write-test
}

run_no_internet() {
  printf 'MODE no-internet\n'
  expect_failure "direct public HTTP without proxy is blocked" direct_public_curl
  expect_success "CoreDNS refuses external recursion" coredns_external_refuses
  expect_failure "direct DNS to external resolver is blocked" direct_external_dns_query
  expect_success "Docker socket is absent" docker_socket_absent
  expect_success "root filesystem write fails" root_filesystem_read_only
  expect_success "explicit tmpfs path is writable" tmp_is_writable
}

run_allowlisted() {
  printf 'MODE allowlisted-egress\n'
  expect_success "proxied allowed domain succeeds" proxied_allowed_curl
  expect_failure "proxied non-allowed domain is denied" proxied_denied_domain_curl
  expect_failure "direct public HTTP without proxy is blocked" direct_public_curl
  expect_failure "proxied private target is denied" proxied_private_curl
  expect_failure "proxied LAN target is denied" proxied_lan_curl
  expect_failure "proxied cloud metadata target is denied" proxied_metadata_curl
  expect_failure "proxied raw IP HTTPS target is denied" proxied_raw_ip_connect
  expect_success "CoreDNS refuses external recursion" coredns_external_refuses
  expect_failure "direct DNS to external resolver is blocked" direct_external_dns_query
  expect_success "Docker socket is absent" docker_socket_absent
  expect_success "root filesystem write fails" root_filesystem_read_only
  expect_success "explicit tmpfs path is writable" tmp_is_writable
  todo "SNI mismatch protection is M3: Squid CONNECT host allowlisting is enforced, TLS SNI peek/splice is not enabled"
}

run_fail_closed() {
  printf 'MODE fail-closed\n'
  expect_failure "proxied allowed domain fails when egress-proxy is stopped" proxied_allowed_curl
}

case "$mode" in
  no-internet|allowlisted|fail-closed)
    ;;
  *)
    printf 'Usage: %s {no-internet|allowlisted|fail-closed}\n' "$0" >&2
    exit 2
    ;;
esac

require_tool curl
require_tool dig

case "$mode" in
  no-internet)
    run_no_internet
    ;;
  allowlisted)
    run_allowlisted
    ;;
  fail-closed)
    run_fail_closed
    ;;
esac

printf 'SUMMARY failures=%s not_implemented=%s\n' "$failures" "$not_implemented"

if [ "$failures" -ne 0 ]; then
  exit 1
fi
