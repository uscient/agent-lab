#!/usr/bin/env bash
set -euo pipefail

# Runtime containment assertions, RUN INSIDE the agent container by scripts/agent-test.
# Requires a Docker daemon (and, for the allow mode, outbound internet to the registry).
#   mode deny  -> base recipe: assert containment + deny-by-default egress.
#   mode allow -> node-dev recipe: assert the allowlisted registry is reachable, others not.

mode="${1:-deny}"
failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }
expect_success() { local n="$1"; shift; if "$@"; then pass "$n"; else fail "$n"; fi; }
expect_failure() { local n="$1"; shift; if "$@"; then fail "$n"; else pass "$n"; fi; }

allow_domain="${AGENT_LAB_AGENT_TEST_ALLOW_DOMAIN:-registry.npmjs.org}"
deny_domain="${AGENT_LAB_AGENT_TEST_DENY_DOMAIN:-example.com}"
proxy_url="${HTTPS_PROXY:-${HTTP_PROXY:-http://172.30.0.20:3128}}"

root_write_fails()      { ! touch /agent-lab-root-write-test 2>/dev/null; }
workspace_writable()    { touch /workspace/.agent-lab-write-test 2>/dev/null && rm -f /workspace/.agent-lab-write-test; }
home_writable()         { touch "${HOME:-/home/agent}/.agent-lab-write-test" 2>/dev/null && rm -f "${HOME:-/home/agent}/.agent-lab-write-test"; }
tmp_writable()          { touch /tmp/.agent-lab-write-test 2>/dev/null; }
secret_in_env()         { [ "${AGENT_LAB_TEST_SECRET:-}" = "sentinel-ok" ]; }
secrets_mount_readonly() { ! touch /run/agent-secrets/.agent-lab-write-test 2>/dev/null; }
docker_socket_absent()  { test ! -e /var/run/docker.sock; }
proxied_allow()         { curl -fsS --proxy "$proxy_url" --connect-timeout 5 --max-time 20 "https://${allow_domain}/" >/dev/null 2>&1; }
proxied_deny()          { curl -fsS --proxy "$proxy_url" --connect-timeout 5 --max-time 15 "https://${deny_domain}/" >/dev/null 2>&1; }
direct_blocked()        { curl -fsS --noproxy '*' --connect-timeout 4 --max-time 8 "https://${allow_domain}/" >/dev/null 2>&1; }

printf 'MODE agent-%s\n' "$mode"
expect_success "root filesystem write fails (read-only rootfs)" root_write_fails
expect_success "/workspace is writable"                         workspace_writable
expect_success "/home/agent is writable"                        home_writable
expect_success "/tmp is writable"                               tmp_writable
expect_success "secret file is loaded into env"                 secret_in_env
expect_success "secrets mount is read-only"                     secrets_mount_readonly
expect_success "Docker socket is absent"                        docker_socket_absent
expect_failure "direct (no-proxy) egress is blocked"            direct_blocked

case "$mode" in
  deny)
    expect_failure "deny-by-default: base (empty) allowlist denies all egress" proxied_deny
    ;;
  allow)
    expect_success "allowlisted domain is reachable via the proxy"  proxied_allow
    expect_failure "non-allowlisted domain is still denied"         proxied_deny
    ;;
  *)
    fail "unknown mode: $mode"
    ;;
esac

printf 'SUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
