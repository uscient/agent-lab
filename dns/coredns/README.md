# CoreDNS

CoreDNS is the resolver pinned into agent/test containers on the internal `agents` network.

The Corefile:

- Listens on port 53 inside the `agents` network.
- Logs queries to container stdout.
- Answers only static lab names for CoreDNS and Squid.
- Returns NXDOMAIN for arbitrary external names by using the `hosts` plugin
  without fallthrough.
- Does not forward to public resolvers, host resolvers, or Docker's embedded resolver.

External name resolution for allowed outbound requests is done by Squid on the `egress` network. Agent/test containers should not receive arbitrary external A or AAAA records.

CoreDNS does not write query logs into the `audit` volume because the stock CoreDNS log plugin writes to stdout. Squid proxy logs are stored in `audit`.
