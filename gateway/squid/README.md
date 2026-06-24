# Squid Egress Proxy

Squid is the only service attached to both the internal `agents` network and the internet-capable `egress` network.

The policy:

- Listens on port `3128` inside Docker networks only.
- Allows clients only from `172.30.0.0/24`.
- Allows only ports 80 and 443.
- Allows `CONNECT` only to port 443.
- Denies private, loopback, link-local, multicast, reserved, and cloud-metadata ranges listed in `policies/lan.denylist.example`.
- Allows only domains listed in `policies/egress.allowlist.example`.
- Denies raw IP hostnames where Squid can identify them.
- Defaults to deny all other requests.
- Writes `access.log` and `cache.log` to the `audit` volume.
- Disables caching for agent traffic.

## TLS/SNI Status

TLS SNI peek/splice is not implemented. Squid currently enforces the CONNECT hostname/domain allowlist before tunneling HTTPS, but it does not inspect the TLS ClientHello SNI.

This means the lab has not proven protection against a crafted client that CONNECTs to an allowed hostname while sending a different SNI value inside TLS. That remains a TODO and must be validated before claiming SNI mismatch protection.

## Hardening Status

The Squid service uses no public ports, no Docker socket, no privileged mode, and no host home mounts. `read_only: true` and aggressive capability dropping are deferred until Squid boot behavior is validated with the chosen image, because over-hardening the proxy into a non-booting service would create a misleading boundary.
