# agent-lab — OpenClaw Addition Plan (v0)

> **SUPERSEDED HISTORICAL CONTEXT.** Do not implement this plan as written.
> It recommends using the upstream GHCR image as the v0 trust anchor, which is
> no longer the approved direction. Current M1 work uses
> `images/openclaw/openclaw.lock`, `scripts/openclaw-fetch-source`, and
> `images/openclaw/Dockerfile` to self-build from a verified pinned OpenClaw
> source commit.

> Planning only — no runtime code is created here. Source of truth is `AGENTS.md`;
> if this plan disagrees with it, `AGENTS.md` wins. Companion to `PLAN.md`
> (base lab design); this document covers **only** the OpenClaw addition and
> supersedes `PLAN.md` §11 for OpenClaw specifics.
>
> Validation caveat: `docker` / `docker compose` were unavailable in the authoring
> environment, so every Compose/Dockerfile snippet below is **illustrative and
> unvalidated**. Each must be checked with `docker compose config` during
> implementation.
>
> Fact legend: **[V]** = verified from a cited upstream source (see §2 / Sources).
> **[A]** = assumption or inference that implementation must verify before relying
> on it. Do not treat **[A]** items as confirmed.

---

## 1. Executive recommendation

Add OpenClaw as a **non-default Compose profile (`openclaw`)** built on the
**pinned official image** `ghcr.io/openclaw/openclaw` **[V]**, wrapped strictly by
agent-lab containment, with **OpenClaw's own Docker sandbox backend turned OFF**.
Concretely (the recommendation is **Option 1 + Option 7**, see §4–§5):

- Pin `ghcr.io/openclaw/openclaw` **by digest**; do not build from source in v0.
  The official image is already `node:24-bookworm-slim`, non-root (`node`, uid
  1000), tini entrypoint **[V]** — it is constrainable enough with Compose, so a
  custom/source build is not justified yet.
- **Sandbox off** (`agents.defaults.sandbox.mode: "off"`, `OPENCLAW_SANDBOX`
  unset) **[V: docker backend requires the Docker socket]**. We do **not** mount
  `/var/run/docker.sock`. Tool execution runs inside the already-jailed gateway
  container; agent-lab is the containment boundary, not OpenClaw's nested sandbox.
- Put OpenClaw on a **dedicated internal network `openclaw_net`** (not the shared
  `agents` net) with **only CoreDNS and the Squid egress-proxy** also attached.
  This prevents cross-service reachability of the gateway's `18789` port and
  stops OpenClaw from reaching other agents. (Tradeoff analysis in §8.)
- **Operator access:** publish `127.0.0.1:${OPENCLAW_PORT:-18789}:18789` only.
  In-container the gateway must bind all interfaces (`lan`/`custom`) for the
  published port to work; isolation comes from the localhost-only host publish +
  the dedicated network + the gateway auth token (see §12).
- **Secrets:** gateway token lives in the config-volume `.env` (written by
  onboarding), provider creds in OpenClaw's **encrypted** auth-profile store on a
  named volume; reference any file secrets via OpenClaw `SecretRef` from
  `:ro secrets/openclaw/` **[V: SecretRef supports file source]**. **No secrets in
  `.env.local`, none in Compose `environment:`** (avoids `docker inspect` leak).
- **No host mounts, no `host.docker.internal`, no public ports, no privilege.**
  `read_only` rootfs + tmpfs + three named volumes (config, workspace,
  auth-secret). `cap_drop: ALL`, `no-new-privileges`, resource limits.
- **No messaging channels and no browser/Playwright in v0.** Minimal model path
  is one cloud provider domain allowlisted (`openclaw-cloud-llm`) or an in-lab
  Ollama (`openclaw-local-llm`) — both as profiles, not defaults.
- **Fails closed:** with no route off `openclaw_net` except via Squid, if
  Squid/CoreDNS are down OpenClaw cannot reach anything. Enforcement is the
  internal network, **not** `HTTP_PROXY` (which Node may ignore — see §11).

This is the smallest working, tightly-bounded OpenClaw profile. It is not a
perfect sandbox (shared kernel; see §19).

---

## 2. Upstream OpenClaw facts verified

All items below are **[V]** with sources in the Sources section. Anything not
listed here is treated as **[A]** in later sections.

| Fact | Value |
|---|---|
| Canonical repo | `github.com/openclaw/openclaw` (formerly ClawdBot/MoltBot); npm pkg `openclaw` |
| Official image | `ghcr.io/openclaw/openclaw`, tags `main` / `latest` / `<version>` (e.g. `2026.2.26`); local build → `openclaw:local` via `./scripts/docker/setup.sh` |
| Base image / runtime | `node:24-bookworm-slim` + `tini` entrypoint; Node 22+ required |
| Container user | **non-root**: `node`, uid **1000** |
| Compose services (upstream) | `openclaw-gateway` and `openclaw-cli` |
| Default port | `18789` (web/control UI) |
| Default bind | `OPENCLAW_GATEWAY_BIND=lan`; other modes `loopback`, `custom`, `tailnet`, `auto`; config keys `gateway.bind`, `gateway.port: 18789` |
| Config dir | `/home/node/.openclaw` (`OPENCLAW_CONFIG_DIR`); holds JSON5 `openclaw.json`, auth profiles, `.env`; override path via `OPENCLAW_CONFIG_PATH` (real file, not symlink) |
| Workspace dir | `/home/node/.openclaw/workspace` (`OPENCLAW_WORKSPACE_DIR`) |
| Auth secret key dir | `/home/node/.config/openclaw` (`OPENCLAW_AUTH_PROFILE_SECRET_DIR`) |
| Logs | `/tmp/openclaw/` |
| Gateway token | `OPENCLAW_GATEWAY_TOKEN` written to config-dir `.env` during setup; config also has `gateway.auth.token` / `gateway.auth.password` |
| Provider creds | stored **encrypted** at `agents/<agentId>/agent/auth-profiles.json`; config supports `SecretRef` (sources: env, **file**, exec command) |
| Sandbox | `agents.defaults.sandbox` with `mode` (`off`/`non-main`/`all`) and `scope` (`session`/`agent`/`shared`); **Docker backend requires the Docker socket**; `OPENCLAW_SANDBOX` to enable; `OPENCLAW_DOCKER_SOCKET` to override socket path (rootless); setup via `scripts/sandbox-setup.sh` |
| Host gateway | `host.docker.internal` **required** to reach host-local providers (Ollama, LM Studio) |
| Onboarding | interactive `openclaw onboard` wizard; `OPENCLAW_SKIP_ONBOARDING` to skip |
| CLI usage | `docker compose run --rm openclaw-cli status` / `pairing approve <channel> <code>` / `dashboard --no-open` |
| Config reload | watches config; modes `hybrid` (default) / `hot` / `restart` / `off` |
| Telemetry | accepts `OTEL_EXPORTER_OTLP_ENDPOINT` and other OTEL env vars |
| Channels | WhatsApp, Telegram, Slack, Discord, Signal, iMessage, Matrix, Teams, IRC, and many more |
| Arch | hub-and-spoke: single **Gateway** (WebSocket control plane) + **Agent Runtime** loop; multi-agent, each with own `workspace`/`agentDir`/sessions |

**Not yet verified [A] (must confirm in implementation):** exact full set of
writable paths needed for a read-only rootfs (Node/npm caches, plugin dirs);
whether OpenClaw/Node honors `HTTP_PROXY`/`HTTPS_PROXY` for model API calls;
whether the gateway makes any mandatory outbound call at startup (update/license/
telemetry) that a tight allowlist would block; whether `OPENCLAW_GATEWAY_BIND=custom`
can bind a single non-loopback interface so we avoid `0.0.0.0`.

---

## 3. Security-sensitive OpenClaw behaviors

Treat OpenClaw as a **powerful, hostile-capable runtime**, not a utility:

- **It is designed to act:** run shell commands, control a browser, read/write
  files, send messages/email, manage calendars — triggered by inbound chat **[V]**.
  Prompt injection through a channel is a direct path to tool execution.
- **Built-in sandbox wants the Docker socket [V].** Enabling it to get nested
  isolation would hand a container the ability to spawn host-side containers — a
  host-control primitive. We refuse it in v0 (§5, §19).
- **Default bind is `lan` [V]** — listens broadly; safe only if the host publish
  is localhost-scoped and the network is narrowed.
- **`host.docker.internal` for local models [V]** — pulls the container toward the
  host gateway; we decline and use in-lab services instead.
- **Many inbound channels [V]** — each is an external control surface and an
  egress destination. All off by default.
- **Secrets sprawl [V]:** gateway token in `.env`, encrypted auth profiles, plus a
  separate auth-secret key dir. Mishandling leaks via env/inspect/logs/backups.
- **Plugins/skills** can run code and may ignore proxy env — the internal network
  must be the real boundary.
- **Telemetry (OTEL) configurable [V]** — must stay off and unallowlisted.

---

## 4. Recommended v0 approach

**Option 1 (official image + strict Compose wrapping) + Option 7 (built-in
sandbox disabled, rely on agent-lab containment).**

Why this combination:
- Lowest patch/update burden and best upstream compatibility — we consume the
  official, already-non-root image and override only what containment needs.
- The official image is constrainable enough with Compose (non-root, slim base),
  so building from source (Option 2/4) buys little and risks breaking native
  modules/plugins.
- Disabling the Docker sandbox removes the single biggest policy conflict (socket
  access) while keeping OpenClaw fully functional inside the agent-lab jail. With
  sandbox off, tool execution happens **inside the gateway container**, which is
  already non-root, capability-stripped, read-only-rootfs, and egress-restricted.
- Keep upstream's `gateway` + `cli` split (Option 5, partial) — it maps cleanly to
  a long-running service + one-shot CLI/onboarding services.

v0 shape: pinned `ghcr.io/openclaw/openclaw` digest → `openclaw-gateway` service on
`openclaw_net` (internal) → CoreDNS resolver + Squid the only egress → named
volumes for config/workspace/auth-secret → localhost-only published `18789` →
sandbox off, channels off, browser off, one model profile.

An **optional thin wrapper image (Option 3)** is deferred: only build it later if
we need to bake in safe defaults (forced bind/proxy config, telemetry off,
stripped tooling). Not required for v0.

---

## 5. Rejected approaches and why

| Option | Verdict | Reason |
|---|---|---|
| 1. Official image + strict Compose | **Chosen** | Smallest, upstream-compatible, image already non-root/slim **[V]** |
| 2. Build from OpenClaw source | Rejected v0 | High patch+update burden; risks breaking native modules/plugins; no security gain over constrained official image |
| 3. Thin wrapper image | Deferred | Useful later to bake safe defaults; unnecessary for v0 |
| 4. Hardened custom slim/Node image | Rejected v0 | Largest burden; Alpine/musl risks breaking Node native deps **[A]**; official base is already reasonable |
| 5. Split gateway/cli/sandbox/browser services | Partial | Keep gateway+cli (upstream already does **[V]**); no sandbox workers (sandbox off); browser/tools deferred |
| 6. Use built-in Docker sandbox | **Rejected v0** | Requires `/var/run/docker.sock` **[V]** → violates no-socket policy; host-control primitive |
| 7. Disable built-in sandbox, rely on agent-lab | **Chosen** | Removes socket need; agent-lab jail is the boundary |
| 8. Rootless Docker / socket-proxy for sandbox | Deferred | Only relevant if we ever re-enable sandbox; document as the **safe** way to do it later (rootless socket via `OPENCLAW_DOCKER_SOCKET` **[V]**, or a locked-down socket-proxy), behind `openclaw-danger-zone` |

---

## 6. Docker image strategy

- **v0: consume the official image, pinned by digest.**
  `image: ghcr.io/openclaw/openclaw@sha256:<digest>` (resolve a specific
  `<version>` tag like `2026.2.26` to its digest; never run `latest`/`main`
  unpinned — `AGENTS.md` allows unpinned only in clearly-marked experimental
  profiles).
- **Base/runtime [V]:** `node:24-bookworm-slim`, non-root `node` uid 1000, tini.
  Debian-slim (not Alpine) is the pragmatic choice — avoids musl breakage of Node
  native modules and Playwright; distroless is unrealistic because OpenClaw expects
  a shell/Node tooling at runtime **[A]**.
- **Do not** strip the official image in v0 (we don't rebuild it). If a thin
  wrapper is added later (Option 3), then: remove package managers post-build,
  drop `git`/`python`/build tooling unless a plugin needs them, split a minimal
  `openclaw-gateway` image from a tool-rich `openclaw-tools`/`openclaw-browser`
  image, add SBOM and OCI labels, and re-pin by digest.
- **Labels/metadata (for our Compose + any wrapper):** record
  `agent-lab.profile=openclaw`, `agent-lab.network=openclaw_net`,
  `agent-lab.egress=mediated`, `agent-lab.sandbox=off`.
- **Update strategy:** bump the pinned digest deliberately in one reviewable
  patch; review upstream changelog for new socket/host/channel defaults that could
  re-introduce conflicts; re-run the §18 tests before accepting.
- **v0 image profiles:** only the gateway. Defer `openclaw-tools`,
  `openclaw-browser`, and any `danger-zone` image.

---

## 7. Compose profile design

- All OpenClaw services carry `profiles: ["openclaw"]` (or the model/maintenance
  sub-profiles) → **never start by default** (`AGENTS.md` + hard constraint).
- Services:
  - `openclaw-gateway` (long-running) — the contained gateway.
  - `openclaw-onboard` (one-shot, profile `openclaw-onboard`) — runs
    `openclaw onboard`, writes only to OpenClaw named volumes.
  - `openclaw-cli` (one-shot, profile `openclaw-cli`) — `docker compose run --rm`
    management commands.
- **Sub-profiles (minimal set, see §13/§14):** `openclaw-cloud-llm`,
  `openclaw-local-llm`, `openclaw-maintenance-egress`. Deferred: `openclaw-browser`,
  `openclaw-tools`, `openclaw-danger-zone`.
- File: `profiles/openclaw.compose.yaml` (+ optional
  `profiles/openclaw.local-llm.compose.yaml` / `openclaw.cloud-llm.compose.yaml`
  if it keeps files readable).
- Depends-on: gateway `depends_on` CoreDNS + Squid (with `condition:
  service_healthy` where healthchecks exist) so it doesn't start before its only
  egress path — but note this is ordering, not a security guarantee; the network
  is what enforces fail-closed.

---

## 8. Network design and service-access policy

**Decision: dedicated internal network `openclaw_net`, not the shared `agents`
net.** Rationale (the explicit tradeoff):

- A single shared `agents` net is simple but flat: any container on it could reach
  the gateway's `18789` (which binds all interfaces in-container), and OpenClaw
  could probe other agents. That violates least-reachability.
- `openclaw_net` (`internal: true`) with **only** `openclaw-gateway`, CoreDNS, and
  Squid attached gives OpenClaw exactly three reachable peers: DNS, the egress
  proxy, and its own listener. Nothing else.

Concretely:

- `openclaw_net`: `internal: true`, IPv4 only.
- **CoreDNS** is multi-homed onto `agents` **and** `openclaw_net` (a resolver,
  does not route between them).
- **Squid** is the only multi-homed egress component: `agents` + `openclaw_net` +
  `egress`. It is an application proxy (no IP forwarding), so attaching it to both
  internal nets does **not** bridge them — `openclaw_net` still cannot reach
  `agents`.
- **Service names vs static IPs:** use Compose **service names** (Docker embedded
  DNS resolves them); pin OpenClaw's `dns:` to CoreDNS so external names don't
  leak (per `PLAN.md` §8). Static IPs only if a config needs a literal proxy/DNS
  address; otherwise names are clearer.
- **Reaching optional internal services** (Ollama/LiteLLM): attach OpenClaw to a
  shared `models` internal net **only when** `openclaw-local-llm`/`-cloud-llm`
  active, and reach those services by name — never via `host.docker.internal`.
- **Per-agent vs shared:** adopt **per-profile narrow nets** as the pattern
  (`openclaw_net`, future `hermes_net`, …), each with only DNS+proxy +
  explicitly-shared services. This prevents accidental cross-reachability as
  profiles grow.
- **Invariant to document:** "only the Squid egress-proxy is dual/multi-homed onto
  an internet-capable network; every agent/profile net is `internal: true`." Put
  this in `docs/openclaw.md` and `THREAT_MODEL.md`.
- **Tests (see §18):** assert OpenClaw is **not** on `egress`; assert it **cannot**
  reach a probe container parked on `agents`; assert it can reach only CoreDNS +
  Squid.

---

## 9. Filesystem, users, permissions, and writable paths

- **User:** keep upstream `node` **uid/gid 1000** **[V]** (don't fight the image's
  baked ownership with a custom 10001 — volume ownership would mismatch). Set
  `user: "1000:1000"` defensively to match.
- **Read-only root filesystem:** target `read_only: true`. Provide writable
  surfaces only at OpenClaw's known write paths:

| Path | Mount | Why |
|---|---|---|
| `/home/node/.openclaw` | named volume `openclaw_config` | config, `openclaw.json`, `.env`, auth profiles **[V]** |
| `/home/node/.openclaw/workspace` | named volume `openclaw_workspace` (nested mount shadows the parent) | agent working files **[V]**; separated so reset preserves only intended state |
| `/home/node/.config/openclaw` | named volume `openclaw_auth_secret` | auth-profile encryption key dir **[V]**; the crown-jewel volume |
| `/tmp` (incl. `/tmp/openclaw`) | tmpfs | logs + scratch **[V]**; ephemeral |
| `/run` | tmpfs | runtime |
| `/home/node/.npm`, `/home/node/.cache` | tmpfs **[A]** | Node/npm may write caches; confirm and add only if needed |

- **Permissions:** volumes owned by `1000:1000`; secret mounts `:ro` and mode
  `0400`/`0440`. Auth-secret volume treated as most sensitive.
- **Onboarding writes:** must land **only** in the named volumes above — never in
  tracked repo files. An `openclaw-onboard` one-shot service mounts the same
  volumes and runs the wizard; nothing is written to the host repo.
- **CLI:** `openclaw-cli` as a separate one-shot `docker compose run --rm` service
  with the **same constraints** (own ephemeral container, same volumes, same net).
  Do **not** share the gateway's network namespace; keep it independently
  constrained. (`docker compose exec` into the gateway remains available for
  debugging but is not the default path.)
- **Must be writable:** the three volumes + tmpfs above. **Must stay read-only:**
  `/etc`, `/usr`, the app source (`/app` or wherever `dist/` lives), and the rest
  of the rootfs — tested in §18.

---

## 10. Secrets and identity handling

- **Gateway token:** generated by onboarding into the config-volume `.env` **[V]**.
  Keep it there (named volume). **Do not** set `OPENCLAW_GATEWAY_TOKEN` via Compose
  `environment:` and **do not** place it in `.env.local` — that would expose it in
  `docker inspect`. Preference: **no OpenClaw token in `.env.local` at all.**
- **Provider API keys / OAuth:** use OpenClaw's **encrypted auth-profile store**
  **[V]** on `openclaw_config`, with the encryption key on `openclaw_auth_secret`.
  Where a config value must reference a secret, use **`SecretRef` with a file
  source** **[V]** pointing at a `:ro` mount from gitignored `secrets/openclaw/` —
  never an env var.
- **Where secrets live:** `secrets/openclaw/` (gitignored; `secrets/` already in
  `.gitignore`) for any file-mounted secret; everything else inside the encrypted
  store on named volumes. Nothing secret in the repo.
- **Avoid leaks:**
  - `docker inspect` → keep secrets out of `environment:` (use files/volumes).
  - logs → confirm OpenClaw doesn't echo secrets at its log level **[A]**; test that
    logs don't contain token/key values (§18).
  - backups → the encrypted profiles are useless without `openclaw_auth_secret`;
    document that backing up `openclaw_config` without the key volume is the safer
    default, and treat the key volume as crown jewels.
- **Rotation/reset:** `scripts/openclaw-reset` tears down the gateway and
  recreates the secret/config volumes (or runs an OpenClaw reset command if one
  exists **[A]**), forcing re-onboarding. Rotating the gateway token = re-run
  onboarding or edit the config-volume `.env`.
- **Gitignore:** ensure `secrets/openclaw/`, `*.local`, and any `openclaw*.env`
  (non-example) are ignored. Commit only `env/openclaw.env.example` and
  `policies/openclaw.egress.allowlist.example` with placeholders.

---

## 11. Egress and DNS behavior

- **Enforcement is the internal network, not proxy env.** `openclaw_net` is
  `internal: true`; the only off-net path is Squid. Even if OpenClaw or a plugin
  ignores `HTTP_PROXY`, a direct connection has no route and **fails closed**.
- **Proxy env vars (function, not security):** set `HTTP_PROXY`/`HTTPS_PROXY` =
  Squid and `NO_PROXY` = internal service names + `localhost,127.0.0.1`. **Caveat
  [A]:** Node's global `fetch`/undici historically does **not** honor `HTTP_PROXY`
  automatically; OpenClaw may need explicit proxy config (or an undici
  `EnvHttpProxyAgent`) for model calls to traverse Squid. Must verify; if it does
  not honor the proxy, model egress simply fails (closed) until wired correctly —
  acceptable posture, but call it out so it isn't mistaken for a bug.
- **DNS:** pin `dns:` to CoreDNS; agents get no external recursion (per `PLAN.md`).
  External names for allowed model APIs are resolved by **Squid** on the egress
  side. Blocks DNS bypass/exfil.
- **Minimal startup allowlist:** ideally **empty** for a bare contained gateway.
  For a usable cloud model, allowlist **only the one provider API domain**
  (e.g. `api.anthropic.com`) in
  `policies/openclaw.egress.allowlist.example`. **Verify [A]** the gateway can
  reach `healthy` with zero allowlist (no mandatory phone-home).
- **Do NOT allowlist by default:** npm/yarn registries, `ghcr.io`, channel
  backends (Telegram/WhatsApp/Slack/…), telemetry/OTEL endpoints, public DoH
  providers, update servers.
- **Model providers:** one domain per provider, added explicitly under
  `openclaw-cloud-llm`. Keep the list minimal and reviewed.
- **Package/plugin installation:** handled as a **deliberate maintenance
  workflow**, not standing egress — a temporary `openclaw-maintenance-egress`
  profile that adds registry domains to the allowlist for the duration of an
  install, then is removed. Never leave registries permanently open.
- **Telemetry:** leave OTEL unset; do not allowlist its endpoint, so it fails
  closed even if a default tries to emit.
- **Tests:** allowed vs denied domain through Squid; direct egress blocked;
  private/LAN/metadata blocked; Squid logs show OpenClaw attempts; fail-closed when
  Squid stopped (§18).

---

## 12. Operator access model

- **Publish localhost-only:** `127.0.0.1:${OPENCLAW_PORT:-18789}:18789`. No public
  bind, no LAN bind, no `0.0.0.0` host publish.
- **In-container bind:** Docker cannot forward a published host port to a process
  listening on the container's own `127.0.0.1`, so `OPENCLAW_GATEWAY_BIND=loopback`
  would break the published port. Use **`lan`** (or `custom`/`auto`) so the gateway
  listens on the container interface; safety is provided by (a) the host publish
  scoped to `127.0.0.1`, (b) the dedicated `openclaw_net` (no other agent can reach
  `18789`), and (c) the **gateway auth token** required for the UI/API **[V]**.
  **Verify [A]** whether `custom` can bind a single interface to avoid `0.0.0.0`
  in-container (would tighten further).
- **No `host.docker.internal` mapping** by default (only a specific local-provider
  profile could add it, and we instead use in-lab Ollama — §13).
- **v0 recommendation:** operator opens `http://127.0.0.1:18789/?token=…` on the
  host; pairing/approval via `openclaw-cli`. Document that the token is required
  and where it lives (config volume, not the repo).

---

## 13. Local model / cloud model integration options

Default gateway wires **no** model egress. Models come via profiles:

| Mode | Profile | How | Egress |
|---|---|---|---|
| Cloud model | `openclaw-cloud-llm` | provider key in encrypted auth profile; allowlist **one** provider API domain; route via Squid | one domain |
| Local model | `openclaw-local-llm` | run **Ollama as an agent-lab service** on a shared `models` internal net; OpenClaw reaches it by service name; attach OpenClaw to `models` only in this profile | **none** (stays in-lab) |
| Model gateway | later | a future LiteLLM service centralizes provider creds + a single allowlist entry; OpenClaw talks only to LiteLLM | one internal hop |

- **Prefer talking to a single model/API gateway** (LiteLLM) over many direct
  provider connections as providers multiply — one allowlist entry, one credential
  store, one audit point. v0 can start with one direct cloud domain to stay small.
- **No `host.docker.internal`** to reach host Ollama/LM Studio — run them inside
  the lab instead, so the host gateway stays unmapped.
- Modes are explicit: "no-tools / local-model / cloud-model / browser" map to
  profile combinations, not always-on defaults.

---

## 14. Onboarding and CLI workflow

```bash
# one-time, writes ONLY into OpenClaw named volumes (not the repo):
./scripts/openclaw-onboard        # docker compose run --rm openclaw-onboard  → `openclaw onboard`
# bring up the contained gateway:
./scripts/up openclaw             # core + egress + openclaw profiles
./scripts/openclaw-health         # checks gateway healthy + containment invariants
# management:
./scripts/openclaw-cli status
./scripts/openclaw-cli pairing approve telegram <CODE>   # only if a channel is later enabled
# reset/rotate:
./scripts/openclaw-reset          # recreate secret/config volumes, force re-onboard
```

- `openclaw-onboard` is a **one-shot service** (`OPENCLAW_SKIP_ONBOARDING` unset for
  this run only) mounting the config/auth/workspace volumes; the long-running
  gateway runs with onboarding skipped and reads the already-written config.
- Scripts pass `--env-file .env.local` for **non-secret** interpolation only (image
  digest, port, profile flags). Secrets never flow through scripts' env.
- All four scripts are non-destructive except `openclaw-reset`, which prompts
  before deleting volumes.

---

## 15. Required files for implementation

Minimal v0 set (✓ = v0, ○ = later):

```text
✓ profiles/openclaw.compose.yaml              # gateway + onboard + cli, hardened
✓ images/openclaw/README.md                   # pinned-official-image strategy + hardening notes
○ images/openclaw/Dockerfile                  # only if a thin wrapper is later needed
○ images/openclaw/entrypoint.sh               # only with a wrapper
✓ policies/openclaw.egress.allowlist.example  # ONE model-provider domain, commented
✓ env/openclaw.env.example                    # non-secret: image digest, port, bind, profile flags
✓ scripts/openclaw-onboard
✓ scripts/openclaw-cli
✓ scripts/openclaw-health
✓ scripts/openclaw-reset
✓ tests/openclaw/README.md
✓ tests/openclaw/cases.sh
✓ docs/openclaw.md                            # operator guide + invariants
✓ docs/openclaw-threat-model.md               # OpenClaw-specific risks (sandbox-off, channels, secrets)
○ profiles/openclaw.cloud-llm.compose.yaml    # first model profile (can start as a fragment in M4)
○ profiles/openclaw.local-llm.compose.yaml    # Ollama in-lab
```

No `Dockerfile` in v0 (we pin the official image). Create dirs as milestones reach
them.

---

## 16. Example Compose shape (illustrative only — unvalidated)

```yaml
# profiles/openclaw.compose.yaml  (depends on base compose.yaml + compose.egress.yaml)
networks:
  openclaw_net:
    internal: true        # no off-net route; only CoreDNS + Squid + gateway attach

volumes:
  openclaw_config:        # /home/node/.openclaw  (config, openclaw.json, .env, auth profiles)
  openclaw_workspace:     # /home/node/.openclaw/workspace (nested mount)
  openclaw_auth_secret:   # /home/node/.config/openclaw (encryption key — crown jewels)

services:
  openclaw-gateway:
    image: ghcr.io/openclaw/openclaw@sha256:<pinned-digest>
    profiles: ["openclaw"]
    networks: [openclaw_net]                 # NEVER egress; NEVER agents
    dns: ["<coredns-on-openclaw_net>"]
    ports:
      - "127.0.0.1:${OPENCLAW_PORT:-18789}:18789"   # localhost only
    environment:
      OPENCLAW_GATEWAY_BIND: "lan"           # binds container iface so the publish works (see §12)
      OPENCLAW_SKIP_ONBOARDING: "1"          # gateway reads pre-written config
      HTTP_PROXY: ${HTTP_PROXY}              # function only; NOT the security boundary (§11)
      HTTPS_PROXY: ${HTTPS_PROXY}
      NO_PROXY: ${NO_PROXY}
      # NO OPENCLAW_SANDBOX  -> built-in Docker sandbox stays OFF (no socket)
      # NO secrets here (would leak via docker inspect)
    volumes:
      - openclaw_config:/home/node/.openclaw
      - openclaw_workspace:/home/node/.openclaw/workspace
      - openclaw_auth_secret:/home/node/.config/openclaw
      # - ./secrets/openclaw/<name>:/run/secrets/<name>:ro   # only if a SecretRef file is used
    user: "1000:1000"
    read_only: true
    tmpfs: ["/tmp", "/run"]                   # add /home/node/.npm,.cache if needed [A]
    security_opt: ["no-new-privileges:true"]
    cap_drop: ["ALL"]
    pids_limit: 512
    mem_limit: 2g
    cpus: 2.0
    # no /var/run/docker.sock, no host bind mounts, no host.docker.internal, not privileged
    depends_on: [dns, egress-proxy]
    healthcheck:
      test: ["CMD", "node", "-e", "fetch('http://127.0.0.1:18789/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]  # [A] confirm health path
      interval: 30s
      retries: 3
    restart: unless-stopped

  openclaw-onboard:
    image: ghcr.io/openclaw/openclaw@sha256:<pinned-digest>
    profiles: ["openclaw-onboard"]
    networks: [openclaw_net]
    dns: ["<coredns-on-openclaw_net>"]
    entrypoint: ["openclaw", "onboard"]       # [A] confirm CLI entry; writes only to volumes
    volumes:
      - openclaw_config:/home/node/.openclaw
      - openclaw_workspace:/home/node/.openclaw/workspace
      - openclaw_auth_secret:/home/node/.config/openclaw
    user: "1000:1000"
    security_opt: ["no-new-privileges:true"]
    cap_drop: ["ALL"]
    restart: "no"

  openclaw-cli:
    image: ghcr.io/openclaw/openclaw@sha256:<pinned-digest>
    profiles: ["openclaw-cli"]
    networks: [openclaw_net]
    dns: ["<coredns-on-openclaw_net>"]
    entrypoint: ["openclaw"]                  # args via `docker compose run --rm openclaw-cli ...`
    volumes:
      - openclaw_config:/home/node/.openclaw
      - openclaw_auth_secret:/home/node/.config/openclaw
    user: "1000:1000"
    read_only: true
    tmpfs: ["/tmp", "/run"]
    security_opt: ["no-new-privileges:true"]
    cap_drop: ["ALL"]
    restart: "no"
```

CoreDNS and Squid (defined in base/egress compose) gain `openclaw_net` in their
`networks:` lists so the gateway can reach them; nothing else joins `openclaw_net`.

---

## 17. Example Dockerfile shape (illustrative only — DEFERRED)

v0 uses the pinned official image, so **no Dockerfile is built**. If a thin
wrapper (Option 3) is later justified to bake safe defaults:

```dockerfile
# images/openclaw/Dockerfile  (thin wrapper — only if needed, NOT v0)
FROM ghcr.io/openclaw/openclaw@sha256:<pinned-digest>
# Bake conservative defaults so they can't be forgotten:
ENV OPENCLAW_GATEWAY_BIND=lan \
    OPENCLAW_SKIP_ONBOARDING=1
# (optional) drop tooling the gateway doesn't need at runtime; keep node/tini.
# Do NOT add curl/git/python unless a required plugin needs them — document if so.
USER 1000:1000
# Keep upstream entrypoint (tini) + command; add only a thin wrapper if proxy
# wiring (undici EnvHttpProxyAgent) must be injected — see §11 [A].
LABEL agent-lab.profile="openclaw" agent-lab.sandbox="off" agent-lab.egress="mediated"
```

Building from source (Option 2/4) is **not** recommended (see §5).

---

## 18. Test plan

Run from `tests/openclaw/cases.sh` against the running profile (and a disposable
probe on `agents`/`openclaw_net` where needed). Maps 1:1 to the required cases.

| # | Assertion | Check (illustrative) | Expected |
|---|---|---|---|
| 1 | Gateway healthy | compose healthcheck / `openclaw-cli status` | healthy |
| 2 | Only approved nets | `docker inspect` networks of gateway | `openclaw_net` only |
| 3 | Not on `egress` | inspect networks | `egress` absent |
| 4 | No Docker socket | `test ! -e /var/run/docker.sock` in container | pass |
| 5 | No host home mount | inspect mounts; no `$HOME`/host bind | pass |
| 6 | Not privileged | inspect `Privileged=false`, no `CAP_SYS_ADMIN` | pass |
| 7 | No public port | `docker inspect` port bindings | `127.0.0.1` only |
| 8 | Localhost bind | host `ss -ltnp`/inspect shows `127.0.0.1:18789` | pass |
| 9 | Non-root | `id -u` in container | `1000` |
| 10 | no-new-privileges | inspect `SecurityOpt` | present |
| 11 | Caps restricted | inspect `CapDrop=ALL`, minimal `CapAdd` | pass |
| 12 | Read-only rootfs | inspect `ReadonlyRootfs=true` | pass (or documented exception) |
| 13 | Writable only to approved paths | `touch /home/node/.openclaw/x` ok; `/workspace` ok | pass |
| 14 | Cannot write `/etc`,`/usr`,app src | `touch /etc/x`, `/usr/x`, `/app/x` | fail |
| 15 | Reaches CoreDNS | resolve a service name via CoreDNS | resolves |
| 16 | Reaches Squid | `curl --proxy squid https://<allowed>` | 200 |
| 17 | No direct internet | `curl -m5 https://example.com` (no proxy) | fail/timeout |
| 18 | Allowed domain via proxy only | allowed via Squid vs direct | proxy ok, direct fails |
| 19 | Non-allowed domain blocked | `curl --proxy squid https://<denied>` | 403 |
| 20 | No private/LAN/metadata | `curl` to RFC1918 + `169.254.169.254` | blocked |
| 21 | No arbitrary external DNS | `dig @1.1.1.1 x`; `dig x` via CoreDNS | no route; REFUSED |
| 22 | Fails closed (Squid down) | stop `egress-proxy`; redo #16 | fail |
| 23 | Can't reach unauthorized service | probe container on `agents`; gateway curls it | fail (no route) |
| 24 | Secrets only if mounted | enumerate mounts; only intended `:ro` secret present | pass |
| 25 | No secrets in inspect env | `docker inspect` env has no token/key values | pass |
| 26 | Squid logs OpenClaw egress | grep `audit` Squid log after #16/#19 | present |
| 27 | Logs free of secrets | grep gateway logs for token/key values | absent |
| 28 | Onboarding writes no tracked files | run onboard; `git status --short` | clean |
| 29 | Recreate preserves only intended state | `down` + `up`; config/workspace persist, rootfs reset | pass |

Same honesty note as `PLAN.md`: cases 17/20/21/23 are *blocked* by the internal
network but raw non-proxied attempts are not *logged* without the optional host
nftables layer.

---

## 19. Residual risks and limitations

This is practical Docker containment, **not** a perfect sandbox.

- **Sandbox-off concentration of risk.** With OpenClaw's nested sandbox disabled,
  prompt-injected tool calls (shell/file/etc.) run **inside the gateway
  container**. That container is hardened (non-root, caps dropped, ro-rootfs,
  egress-allowlisted, no socket, no host mount), but there is no *second* nested
  jail. Accepted tradeoff vs. mounting the Docker socket (a worse risk).
- **Gateway holds creds + has mediated egress.** A compromised gateway can exfil to
  the one allowlisted provider domain. Inherent to allowlisting; keep the list
  minimal.
- **`0.0.0.0` in-container bind.** Required for the localhost publish; mitigated by
  dedicated `openclaw_net` + auth token. If any other container is ever added to
  `openclaw_net`, it could reach `18789` — the "only DNS+Squid share this net"
  invariant must hold (tested).
- **Node proxy-env uncertainty [A].** If OpenClaw/undici ignores `HTTP_PROXY`,
  model egress fails closed (good) but needs explicit proxy wiring to function.
- **Channels = large attack surface.** Off by default; enabling any channel adds an
  external control path + egress domain and should be its own reviewed change.
- **Secrets at rest.** Gateway token is plaintext in the config-volume `.env`;
  encrypted profiles depend on the auth-secret volume. Protect those volumes;
  don't back them up to anywhere tracked.
- **Supply chain.** We pin a digest, but `latest`/`main` upstream + plugin installs
  remain risks; maintenance egress is deliberate and temporary.
- **Shared kernel.** A container/kernel/Node-native escape defeats all of the
  above; VM-grade isolation (gVisor/Kata/microVM) is the ceiling, out of v0 scope.
- **`host.docker.internal` temptation.** Declined by default; any profile that adds
  it reintroduces a host path and must be loudly justified.

---

## 20. Milestone plan for Codex implementation

Small, reviewable patches; each ends with `docker compose config`,
`git diff --check`, relevant §18 cases, and an `AGENTS.md`-format report.

- **OC-M0 — Docs & policy stubs.** `docs/openclaw.md`, `docs/openclaw-threat-model.md`,
  `env/openclaw.env.example`, `policies/openclaw.egress.allowlist.example` (one
  provider domain, commented). No runtime.
- **OC-M1 — Gateway profile.** `profiles/openclaw.compose.yaml`: pinned official
  image, `openclaw_net` (internal), CoreDNS+Squid joined to it, three named
  volumes, full hardening (ro-rootfs, tmpfs, cap_drop, no-new-privileges, limits,
  uid 1000), sandbox OFF, localhost publish, **no socket/host mount**. Validate
  `compose config`.
- **OC-M2 — Onboarding & CLI.** `openclaw-onboard`/`openclaw-cli` services +
  `scripts/openclaw-onboard|cli|health|reset`. Verify onboarding writes only to
  volumes (case 28).
- **OC-M3 — Acceptance tests.** `tests/openclaw/cases.sh` + README; run the full
  §18 set incl. fail-closed (22) and unauthorized-service (23). Document the
  read-only-rootfs writable-path findings [A].
- **OC-M4 — First model profile.** `openclaw-cloud-llm`: one provider domain
  allowlisted, secret via encrypted auth profile / `SecretRef` file. Prove
  allow/deny egress + no-secret-in-inspect (24–26).
- **OC-M5 — Later profiles (each its own patch).** `openclaw-local-llm` (in-lab
  Ollama on `models` net), `openclaw-maintenance-egress` (temporary registry
  allowlist), then `openclaw-browser`/`openclaw-tools`, and a fenced
  `openclaw-danger-zone` (documents the rootless-socket / socket-proxy path if the
  built-in sandbox is ever wanted).

---

## 21. Open questions

1. **Proxy honoring [A]:** does OpenClaw/Node route model API calls via
   `HTTP_PROXY`/`HTTPS_PROXY`, or is explicit proxy config / an undici
   `EnvHttpProxyAgent` required?
2. **Startup egress [A]:** can the gateway reach `healthy` with an **empty**
   allowlist (no mandatory update/telemetry/license call)?
3. **Read-only rootfs [A]:** the complete set of writable paths (Node/npm caches,
   plugin dirs) needed beyond config/workspace/auth-secret/tmp.
4. **Bind tightening [A]:** can `OPENCLAW_GATEWAY_BIND=custom` bind a single
   container interface so we avoid `0.0.0.0`?
5. **Health endpoint [A]:** exact health path/command for the Compose healthcheck.
6. **Default model:** which provider seeds `openclaw-cloud-llm`'s single allowlist
   entry — or do we ship `openclaw-local-llm` (Ollama) as the default useful path?
7. **Pin target:** which `<version>` digest to standardize on for v0.
8. **Channels:** confirm **all channels off** for v0 (recommended), deferring any
   channel to its own reviewed profile.
9. **Secret backups:** does the operator want a documented backup flow for the
   `openclaw_auth_secret` crown-jewel volume, or explicitly none?
10. **Reset semantics:** is there an official `openclaw reset`/`logout` command, or
    should `openclaw-reset` operate purely at the volume level?

---

## Sources

- OpenClaw repo — <https://github.com/openclaw/openclaw> (and README:
  <https://github.com/openclaw/openclaw/blob/main/README.md>)
- Docker install — <https://docs.openclaw.ai/install/docker>
- Gateway configuration — <https://docs.openclaw.ai/gateway/configuration>
  (and <https://github.com/openclaw/openclaw/blob/main/docs/gateway/configuration.md>)
- Onboarding — <https://docs.openclaw.ai/start/wizard>,
  <https://docs.openclaw.ai/start/onboarding-overview>,
  <https://docs.openclaw.ai/reference/wizard>
- Multi-agent routing — <https://docs.openclaw.ai/concepts/multi-agent>
- Architecture overview — <https://ppaolo.substack.com/p/openclaw-system-architecture-overview>
- Running OpenClaw in Docker (Simon Willison) — <https://til.simonwillison.net/llms/openclaw-docker>
- Guide (formerly ClawdBot/MoltBot) — <https://milvus.io/blog/openclaw-formerly-clawdbot-moltbot-explained-a-complete-guide-to-the-autonomous-ai-agent.md>
- npm package — <https://www.npmjs.com/package/openclaw>

> Note: several specifics are drawn from a fast read of upstream docs and
> third-party guides; everything marked **[A]** must be confirmed against the
> pinned image/version during OC-M1–M3 before it is relied upon.
