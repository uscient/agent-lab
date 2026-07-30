#!/usr/bin/env bash
# Shared deterministic Docker-security harness. Sourced by tests/docker/*.sh.

DOCKER_TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"

docker_test_infra() {
  printf 'INFRA %s\n' "$*" >&2
  return 125
}

docker_test_init() {
  local suite="$1" host_uid host_gid seed

  command -v docker >/dev/null 2>&1 || {
    docker_test_infra "Docker CLI is unavailable"
    return 125
  }
  docker info >/dev/null 2>&1 || {
    docker_test_infra "Docker daemon is unavailable"
    return 125
  }
  docker compose version >/dev/null 2>&1 || {
    docker_test_infra "Docker Compose v2 is unavailable"
    return 125
  }
  docker image inspect agent-lab/devbox:local >/dev/null 2>&1 || {
    docker_test_infra "required local image is missing: agent-lab/devbox:local"
    return 125
  }

  LAB_WORK="$(mktemp -d)"
  LAB_COPY="$LAB_WORK/repo"
  LAB_ENV_FILE="$LAB_WORK/agent.env"
  mkdir -p "$LAB_COPY"
  if ! git -C "$DOCKER_TEST_ROOT" archive HEAD | tar -x -C "$LAB_COPY"; then
    docker_test_infra "could not create isolated source fixture"
    return 125
  fi

  seed=$((($$ + RANDOM) % 200 + 20))
  LAB_PROJECT="agent-lab-${suite//_/-}-$$-${RANDOM}"
  LAB_AGENTS_SUBNET="10.203.${seed}.0/24"
  LAB_DNS_IP="10.203.${seed}.10"
  LAB_PROXY_IP="10.203.${seed}.20"
  LAB_EGRESS_SUBNET="198.18.${seed}.0/24"
  LAB_HTTP_CANARY_IP="198.18.${seed}.10"
  LAB_UDP_CANARY_IP="198.18.${seed}.11"
  LAB_MARKER="agent-lab-${suite}-$$-${RANDOM}"
  LAB_EXTRA_CONTAINERS=()
  LAB_EXTRA_NETWORKS=()

  sed \
    -e "s/172\\.30\\.0\\.10/${LAB_DNS_IP}/g" \
    -e "s/172\\.30\\.0\\.20/${LAB_PROXY_IP}/g" \
    "$LAB_COPY/dns/coredns/Corefile" > "$LAB_COPY/dns/coredns/Corefile.generated"
  mv "$LAB_COPY/dns/coredns/Corefile.generated" "$LAB_COPY/dns/coredns/Corefile"
  sed \
    -e "s#acl lab_agents src 172\\.30\\.0\\.0/24#acl lab_agents src ${LAB_AGENTS_SUBNET}#" \
    "$LAB_COPY/gateway/squid/squid.conf" > "$LAB_COPY/gateway/squid/squid.conf.generated"
  mv "$LAB_COPY/gateway/squid/squid.conf.generated" "$LAB_COPY/gateway/squid/squid.conf"

  mkdir -p "$LAB_COPY/secrets" "$LAB_COPY/tests/docker/workspace"
  chmod 0777 "$LAB_COPY/tests/docker/workspace"
  host_uid="$(id -u)"
  host_gid="$(id -g)"
  [ "$host_uid" -ne 0 ] || host_uid=1000
  [ "$host_gid" -ne 0 ] || host_gid=1000
  LAB_AGENT_UID="$host_uid"
  LAB_AGENT_GID="$host_gid"

  {
    printf 'AGENT_LAB_AGENTS_SUBNET=%s\n' "$LAB_AGENTS_SUBNET"
    printf 'AGENT_LAB_DNS_IP=%s\n' "$LAB_DNS_IP"
    printf 'AGENT_LAB_PROXY_IP=%s\n' "$LAB_PROXY_IP"
    printf 'AGENT_LAB_PROXY_PORT=3128\n'
    printf 'AGENT_LAB_EGRESS_SUBNET=%s\n' "$LAB_EGRESS_SUBNET"
    printf 'HTTP_PROXY=http://%s:3128\n' "$LAB_PROXY_IP"
    printf 'HTTPS_PROXY=http://%s:3128\n' "$LAB_PROXY_IP"
    printf 'NO_PROXY=localhost,127.0.0.1,::1,%s\n' "$LAB_AGENTS_SUBNET"
  } > "$LAB_ENV_FILE"

  export LAB_WORK LAB_COPY LAB_ENV_FILE LAB_PROJECT
  export LAB_AGENTS_SUBNET LAB_DNS_IP LAB_PROXY_IP LAB_EGRESS_SUBNET
  export LAB_HTTP_CANARY_IP LAB_UDP_CANARY_IP LAB_MARKER
  export LAB_AGENT_UID LAB_AGENT_GID
}

docker_test_compose() {
  (
    cd "$LAB_COPY" || exit 125
    docker compose \
      --project-name "$LAB_PROJECT" \
      --env-file "$LAB_ENV_FILE" \
      -f compose.yaml \
      -f compose.egress.yaml \
      -f compose.agent.yaml \
      -f compose.agent.ephemeral.yaml \
      "$@"
  )
}

docker_test_agent() {
  local recipes="$1"
  shift
  COMPOSE_PROJECT_NAME="$LAB_PROJECT" \
  AGENT_LAB_ENV_FILE="$LAB_ENV_FILE" \
  AGENT_LAB_AGENT_IMAGE="agent-lab/devbox:local" \
  AGENT_LAB_PROJECT_DIR="$LAB_COPY/tests/docker/workspace" \
  AGENT_LAB_SECRETS_DIR="$LAB_COPY/secrets" \
  AGENT_LAB_ALLOWLIST_RECIPES="$recipes" \
  AGENT_LAB_EPHEMERAL_HOME="1" \
  AGENT_LAB_AGENT_UID="$LAB_AGENT_UID" \
  AGENT_LAB_AGENT_GID="$LAB_AGENT_GID" \
  AGENT_LAB_AGENT_MEM="1g" \
  AGENT_LAB_AGENT_CPUS="1" \
  AGENT_LAB_AGENTS_SUBNET="$LAB_AGENTS_SUBNET" \
  AGENT_LAB_DNS_IP="$LAB_DNS_IP" \
  AGENT_LAB_PROXY_IP="$LAB_PROXY_IP" \
  AGENT_LAB_EGRESS_SUBNET="$LAB_EGRESS_SUBNET" \
  HTTP_PROXY="http://${LAB_PROXY_IP}:3128" \
  HTTPS_PROXY="http://${LAB_PROXY_IP}:3128" \
  NO_PROXY="localhost,127.0.0.1,::1,${LAB_AGENTS_SUBNET}" \
    "$LAB_COPY/scripts/agent" -- "$@"
}

docker_test_track_container() {
  LAB_EXTRA_CONTAINERS+=("$1")
}

docker_test_track_network() {
  LAB_EXTRA_NETWORKS+=("$1")
}

docker_test_cleanup() {
  local name
  for name in "${LAB_EXTRA_CONTAINERS[@]:-}"; do
    [ -n "$name" ] && docker rm -f "$name" >/dev/null 2>&1 || true
  done
  for name in "${LAB_EXTRA_NETWORKS[@]:-}"; do
    [ -n "$name" ] && docker network rm "$name" >/dev/null 2>&1 || true
  done
  if [ -n "${LAB_COPY:-}" ] && [ -d "$LAB_COPY" ]; then
    docker_test_compose --profile core --profile egress --profile agent --profile devtools \
      down --volumes --remove-orphans >/dev/null 2>&1 || true
  fi
  [ -n "${LAB_WORK:-}" ] && [ -d "$LAB_WORK" ] && rm -rf "$LAB_WORK"
}

docker_test_start_http_canary() {
  local canary control attempt
  canary="${LAB_PROJECT}-http-canary"
  control="${LAB_PROJECT}-egress-control"
  docker run -d \
    --name "$canary" \
    --network "${LAB_PROJECT}_egress" \
    --ip "$LAB_HTTP_CANARY_IP" \
    --network-alias registry.npmjs.org \
    --read-only \
    --tmpfs /tmp \
    --user 0:0 \
    --entrypoint python3 \
    agent-lab/devbox:local \
    -c 'import http.server
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = self.path.lstrip("/").encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *_args):
        pass
http.server.HTTPServer(("0.0.0.0", 80), Handler).serve_forever()' >/dev/null
  docker_test_track_container "$canary"

  docker run -d \
    --name "$control" \
    --network "${LAB_PROJECT}_egress" \
    --read-only \
    --tmpfs /tmp \
    --entrypoint sleep \
    agent-lab/devbox:local infinity >/dev/null
  docker_test_track_container "$control"
  LAB_HTTP_CANARY="$canary"
  LAB_EGRESS_CONTROL="$control"
  export LAB_HTTP_CANARY LAB_EGRESS_CONTROL

  attempt=0
  while [ "$attempt" -lt 30 ]; do
    if docker exec "$control" \
         curl -fsS --noproxy '*' "http://${LAB_HTTP_CANARY_IP}/${LAB_MARKER}" |
         grep -Fxq "$LAB_MARKER"; then
      return 0
    fi
    sleep 1
    attempt=$((attempt + 1))
  done
  docker_test_infra "HTTP canary did not become ready"
}

docker_test_start_udp_canary() {
  local canary attempt
  canary="${LAB_PROJECT}-udp-canary"
  docker run -d \
    --name "$canary" \
    --network "${LAB_PROJECT}_egress" \
    --ip "$LAB_UDP_CANARY_IP" \
    --read-only \
    --tmpfs /tmp \
    --entrypoint python3 \
    agent-lab/devbox:local \
    -c 'import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("0.0.0.0", 5353))
while True:
    data, peer = s.recvfrom(4096)
    s.sendto(data, peer)' >/dev/null
  docker_test_track_container "$canary"
  LAB_UDP_CANARY="$canary"
  export LAB_UDP_CANARY

  attempt=0
  while [ "$attempt" -lt 30 ]; do
    if docker exec "$LAB_EGRESS_CONTROL" python3 -c \
      'import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(1)
s.sendto(sys.argv[2].encode(), (sys.argv[1], 5353))
data, _ = s.recvfrom(4096)
raise SystemExit(0 if data.decode() == sys.argv[2] else 1)' \
      "$LAB_UDP_CANARY_IP" "$LAB_MARKER"; then
      return 0
    fi
    sleep 1
    attempt=$((attempt + 1))
  done
  docker_test_infra "UDP canary did not become ready"
}

docker_test_proxy_container() {
  docker_test_compose --profile egress ps -q egress-proxy
}

docker_test_require_running_proxy() {
  local container_id state
  container_id="$(docker_test_proxy_container)" || return 125
  [ -n "$container_id" ] || return 125
  state="$(docker inspect --format '{{.State.Running}}' "$container_id" 2>/dev/null)" ||
    return 125
  [ "$state" = "true" ] || return 125
}
