# Containment — the real boundary
TL;DR: Treat the agent as hostile; the sandbox/network posture (not the command guard) is the real boundary — never weaken it (Docker socket, privileged, host-net, secrets, egress). See SECURITY.md / THREAT_MODEL.md.

Agent Lab assumes any agent workload may be prompt-injected or compromised. The guard's string
matching is defense-in-depth — it makes the safe path automatic and catches mistakes and casual
evasion, not a determined adversary. What actually contains a hostile agent:
- the internal `agents` network (`internal: true`) — no route to internet, host, or LAN;
- Squid as the only sanctioned egress (deny-by-default allowlist);
- no Docker socket, no host-home mounts, no privileged containers, no host networking, no public ports;
- secrets loaded at runtime from `secrets/`, never in compose `environment:` or `docker inspect`.

Never introduce any of those into tracked config — the guard hard-stops them, and so should you. If
a task seems to need one, stop: it is a boundary change, and that is the human's call.

Related: [[decision-authority]], [[meta]]. Full detail: `SECURITY.md`, `THREAT_MODEL.md`.
