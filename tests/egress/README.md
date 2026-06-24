# Egress Tests

`./scripts/egress-test` runs the acceptance tests from a disposable `egress-test` container attached only to the internal `agents` network.

## No-Internet Mode

Profiles: `core` and `devtools`. `egress-proxy` is stopped.

Expected results:

- Direct public HTTP without proxy fails.
- CoreDNS refuses external recursion.
- Direct DNS to `1.1.1.1` fails because there is no route.
- `/var/run/docker.sock` does not exist.
- Root filesystem writes fail.
- `/tmp` writes succeed because `/tmp` is an explicit tmpfs.

## Allowlisted-Egress Mode

Profiles: `core`, `egress`, and `devtools`.

Expected results:

- Proxied HTTPS to `AGENT_LAB_ALLOWED_TEST_DOMAIN` succeeds.
- Proxied HTTPS to a non-allowlisted domain fails.
- Direct public HTTP without proxy fails.
- Proxied private, LAN, metadata, and raw-IP targets fail.
- CoreDNS refuses external recursion.
- Direct DNS to `1.1.1.1` fails.
- `/var/run/docker.sock` does not exist.
- Root filesystem writes fail.
- `/tmp` writes succeed because `/tmp` is an explicit tmpfs.

## Fail-Closed Check

After allowlisted mode is verified, the script stops `egress-proxy` and reruns a proxied allowed-domain request. It must fail. The script then starts the proxy again.

## Not Yet Proven

SNI mismatch protection is not implemented. The test output includes a `NOT_IMPLEMENTED` line for this case so it is visible rather than silently skipped. A future change should add validated Squid peek/splice behavior or a different proven SNI control.

Raw direct egress attempts are blocked by the internal network but are not logged. Only proxy-mediated attempts are logged by Squid.
