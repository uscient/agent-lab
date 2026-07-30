#!/usr/bin/env bash
# Shared deterministic Docker-security harness. Sourced by tests/docker/*.sh.

DOCKER_TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
DOCKER_TEST_DEVBOX_IMAGE="agent-lab/devbox:local"
DOCKER_TEST_DNS_IMAGE="coredns/coredns:1.14.3"
DOCKER_TEST_PROXY_IMAGE="ubuntu/squid:5.2-22.04_beta"
DOCKER_TEST_IMAGES_PREPARED=0

docker_test_infra() {
  printf 'INFRA %s\n' "$*" >&2
  return 125
}

docker_test_capture_image() {
  local image="$1" purpose="$2" image_id

  if ! docker image inspect "$image" >/dev/null 2>&1; then
    printf 'PREPARE pulling required %s image before containment: %s\n' \
      "$purpose" "$image" >&2
    if ! docker pull "$image" >&2; then
      docker_test_infra \
        "image preflight could not pull required ${purpose} image: ${image}"
      return 125
    fi
  fi
  image_id="$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null)" || {
    docker_test_infra "image preflight could not inspect ${purpose} image: ${image}"
    return 125
  }
  if [[ ! "$image_id" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    docker_test_infra \
      "image preflight returned an invalid identity for ${purpose} image: ${image}"
    return 125
  fi
  DOCKER_TEST_CAPTURED_IMAGE_ID="$image_id"
}

docker_test_assert_devbox_pin() {
  local image_id

  if [[ ! "${LAB_DEVBOX_IMAGE_ID:-}" =~ ^sha256:[0-9a-f]{64}$ ]] ||
     [ -z "${LAB_DEVBOX_PINNED_REF:-}" ]; then
    docker_test_infra "content-pinned devbox identity is incomplete"
    return 125
  fi
  image_id="$(
    docker image inspect --format '{{.Id}}' "$LAB_DEVBOX_PINNED_REF" 2>/dev/null
  )" || image_id=""
  if [ "$image_id" != "$LAB_DEVBOX_IMAGE_ID" ]; then
    docker_test_infra \
      "content-pinned devbox reference changed before containment: ${LAB_DEVBOX_PINNED_REF}"
    return 125
  fi
}

docker_test_build_probe_image() {
  local dockerfile_hash cases_hash dockerignore_hash
  local devbox_digest source_key source_digest existing_key

  dockerfile_hash="$(
    git -C "$DOCKER_TEST_ROOT" hash-object "$LAB_COPY/tests/egress/Dockerfile"
  )" || {
    docker_test_infra "could not hash the Docker probe fixture definition"
    return 125
  }
  cases_hash="$(
    git -C "$DOCKER_TEST_ROOT" hash-object "$LAB_COPY/tests/egress/cases.sh"
  )" || {
    docker_test_infra "could not hash the Docker probe fixture payload"
    return 125
  }
  dockerignore_hash="$(
    git -C "$DOCKER_TEST_ROOT" hash-object "$LAB_COPY/.dockerignore"
  )" || {
    docker_test_infra "could not hash the Docker probe build-context policy"
    return 125
  }
  devbox_digest="${LAB_DEVBOX_IMAGE_ID#sha256:}"
  source_key="${devbox_digest}-${dockerfile_hash}-${cases_hash}-${dockerignore_hash}"
  if command -v sha256sum >/dev/null 2>&1; then
    source_digest="$(printf '%s' "$source_key" | sha256sum | awk '{print $1}')"
  else
    source_digest="$(printf '%s' "$source_key" | shasum -a 256 | awk '{print $1}')"
  fi
  if [[ ! "$source_digest" =~ ^[0-9a-f]{64}$ ]]; then
    docker_test_infra "could not derive the Docker probe fixture identity"
    return 125
  fi
  LAB_EGRESS_TEST_IMAGE_REF="agent-lab/egress-test:gate-${source_digest}"

  docker_test_assert_devbox_pin || return $?

  existing_key="$(
    docker image inspect --format \
      '{{index .Config.Labels "org.agent-lab.fixture-source"}}' \
      "$LAB_EGRESS_TEST_IMAGE_REF" 2>/dev/null
  )" || existing_key=""
  if [ "$existing_key" != "$source_key" ]; then
    printf 'PREPARE building the content-pinned Docker probe before containment\n' >&2
    if ! docker build \
      --network=none \
      --pull=false \
      --build-arg "AGENT_LAB_DEVBOX_IMAGE=${LAB_DEVBOX_PINNED_REF}" \
      --label "org.agent-lab.fixture-source=${source_key}" \
      -t "$LAB_EGRESS_TEST_IMAGE_REF" \
      -f "$LAB_COPY/tests/egress/Dockerfile" \
      "$LAB_COPY" >&2; then
      docker_test_infra \
        "offline probe-image preflight failed from prepared ${DOCKER_TEST_DEVBOX_IMAGE}"
      return 125
    fi
  fi

  docker_test_capture_image "$LAB_EGRESS_TEST_IMAGE_REF" "egress/DNS probe" ||
    return $?
  LAB_EGRESS_TEST_IMAGE_ID="$DOCKER_TEST_CAPTURED_IMAGE_ID"
  docker_test_assert_devbox_pin || return $?
  existing_key="$(
    docker image inspect --format \
      '{{index .Config.Labels "org.agent-lab.fixture-source"}}' \
      "$LAB_EGRESS_TEST_IMAGE_ID" 2>/dev/null
  )" || existing_key=""
  if [ "$existing_key" != "$source_key" ]; then
    docker_test_infra "Docker probe image does not match its content-pinned fixture inputs"
    return 125
  fi
  if ! docker run --rm --network none --entrypoint /bin/bash \
       "$LAB_EGRESS_TEST_IMAGE_ID" -c \
       'command -v curl >/dev/null && command -v dig >/dev/null &&
        command -v python3 >/dev/null' >/dev/null; then
    docker_test_infra "Docker probe image is missing curl, dig, or python3"
    return 125
  fi
}

docker_test_pin_compose_image() {
  local file="$1" image="$2" image_id="$3" generated
  generated="${file}.image-pins"

  if ! awk -v from="    image: ${image}" -v to="    image: ${image_id}" '
      $0 == from {
        print to
        replacements++
        next
      }
      { print }
      END {
        if (replacements != 1) {
          exit 42
        }
      }
    ' "$file" > "$generated"; then
    docker_test_infra \
      "could not pin exactly one Compose image reference: ${image} in ${file##*/}"
    return 125
  fi
  mv "$generated" "$file"
}

docker_test_prepare_images() {
  docker_test_capture_image "$DOCKER_TEST_DEVBOX_IMAGE" "local devbox" || return $?
  LAB_DEVBOX_IMAGE_ID="$DOCKER_TEST_CAPTURED_IMAGE_ID"
  LAB_DEVBOX_PINNED_REF="agent-lab/devbox:gate-${LAB_DEVBOX_IMAGE_ID#sha256:}"
  if ! docker tag "$LAB_DEVBOX_IMAGE_ID" "$LAB_DEVBOX_PINNED_REF"; then
    docker_test_infra "could not create the content-pinned local devbox reference"
    return 125
  fi
  docker_test_assert_devbox_pin || return $?

  docker_test_capture_image "$DOCKER_TEST_DNS_IMAGE" "CoreDNS runtime" || return $?
  LAB_DNS_IMAGE_ID="$DOCKER_TEST_CAPTURED_IMAGE_ID"

  docker_test_capture_image "$DOCKER_TEST_PROXY_IMAGE" "Squid runtime" || return $?
  LAB_PROXY_IMAGE_ID="$DOCKER_TEST_CAPTURED_IMAGE_ID"

  docker_test_build_probe_image || return $?

  docker_test_pin_compose_image \
    "$LAB_COPY/compose.yaml" "$DOCKER_TEST_DNS_IMAGE" "$LAB_DNS_IMAGE_ID" ||
    return $?
  docker_test_pin_compose_image \
    "$LAB_COPY/compose.egress.yaml" "$DOCKER_TEST_PROXY_IMAGE" "$LAB_PROXY_IMAGE_ID" ||
    return $?
  docker_test_pin_compose_image \
    "$LAB_COPY/compose.egress.yaml" "agent-lab/egress-test:0.1" \
    "$LAB_EGRESS_TEST_IMAGE_ID" || return $?

  # These content-addressed aliases form a shared local cache across sequential suites.
  # Per-suite cleanup must not remove them because another concurrent gate may use them.
  DOCKER_TEST_IMAGES_PREPARED=1
  export LAB_DEVBOX_IMAGE_ID LAB_DEVBOX_PINNED_REF LAB_DNS_IMAGE_ID LAB_PROXY_IMAGE_ID
  export LAB_EGRESS_TEST_IMAGE_ID LAB_EGRESS_TEST_IMAGE_REF
  export DOCKER_TEST_IMAGES_PREPARED
}

docker_test_assert_images_prepared() {
  local image_id purpose

  [ "${DOCKER_TEST_IMAGES_PREPARED:-0}" = 1 ] || {
    docker_test_infra "Docker image preflight did not complete before containment"
    return 125
  }
  for purpose in \
    "devbox:${LAB_DEVBOX_IMAGE_ID:-}" \
    "CoreDNS:${LAB_DNS_IMAGE_ID:-}" \
    "Squid:${LAB_PROXY_IMAGE_ID:-}" \
    "probe:${LAB_EGRESS_TEST_IMAGE_ID:-}"; do
    image_id="${purpose#*:}"
    purpose="${purpose%%:*}"
    if [[ ! "$image_id" =~ ^sha256:[0-9a-f]{64}$ ]] ||
       ! docker image inspect "$image_id" >/dev/null 2>&1; then
      docker_test_infra \
        "prepared ${purpose} image identity is unavailable before containment: ${image_id:-unset}"
      return 125
    fi
  done
  docker_test_assert_devbox_pin
}

docker_test_abandon_init() {
  if [ -n "${LAB_WORK:-}" ] && [ -d "$LAB_WORK" ]; then
    rm -rf "$LAB_WORK"
  fi
  LAB_WORK=""
  LAB_COPY=""
  LAB_ENV_FILE=""
}

docker_test_init() {
  local suite="$1" host_uid host_gid seed prepare_rc

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
  docker image inspect "$DOCKER_TEST_DEVBOX_IMAGE" >/dev/null 2>&1 || {
    docker_test_infra "required local image is missing: ${DOCKER_TEST_DEVBOX_IMAGE}"
    return 125
  }

  LAB_WORK="$(mktemp -d)" || {
    docker_test_infra "could not create isolated fixture directory"
    return 125
  }
  LAB_COPY="$LAB_WORK/repo"
  LAB_ENV_FILE="$LAB_WORK/agent.env"
  if ! mkdir -p "$LAB_COPY"; then
    docker_test_infra "could not create isolated source fixture directory"
    docker_test_abandon_init
    return 125
  fi
  if ! git -C "$DOCKER_TEST_ROOT" archive HEAD | tar -x -C "$LAB_COPY"; then
    docker_test_infra "could not create isolated source fixture"
    docker_test_abandon_init
    return 125
  fi
  prepare_rc=0
  docker_test_prepare_images || prepare_rc=$?
  if [ "$prepare_rc" -ne 0 ]; then
    docker_test_abandon_init
    return "$prepare_rc"
  fi
  docker_test_assert_images_prepared || prepare_rc=$?
  if [ "$prepare_rc" -ne 0 ]; then
    docker_test_abandon_init
    return "$prepare_rc"
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
  docker_test_assert_images_prepared || return $?
  docker_test_agent_image "$LAB_DEVBOX_IMAGE_ID" "$recipes" "$@"
}

docker_test_agent_image() {
  local image="$1" recipes="$2"
  shift 2
  if [ "$image" = "${LAB_DEVBOX_IMAGE_ID:-}" ]; then
    # The strict user-facing config schema accepts repository references, not bare Engine
    # IDs. This local alias is derived from and rechecked against the captured identity.
    image="$LAB_DEVBOX_PINNED_REF"
  fi
  COMPOSE_PROJECT_NAME="$LAB_PROJECT" \
  AGENT_LAB_ENV_FILE="$LAB_ENV_FILE" \
  AGENT_LAB_AGENT_IMAGE="$image" \
  AGENT_LAB_PROJECT_DIR="$LAB_COPY/tests/docker/workspace" \
  AGENT_LAB_SECRETS_DIR="$LAB_COPY/secrets" \
  AGENT_LAB_ALLOWLIST_RECIPES="$recipes" \
  AGENT_LAB_EPHEMERAL_HOME="${LAB_EPHEMERAL_HOME:-1}" \
  AGENT_LAB_AGENT_UID="$LAB_AGENT_UID" \
  AGENT_LAB_AGENT_GID="$LAB_AGENT_GID" \
  AGENT_LAB_AGENT_MEM="1g" \
  AGENT_LAB_AGENT_CPUS="1" \
  AGENT_LAB_AGENTS_SUBNET="$LAB_AGENTS_SUBNET" \
  AGENT_LAB_DNS_IP="$LAB_DNS_IP" \
  AGENT_LAB_PROXY_IP="$LAB_PROXY_IP" \
  AGENT_LAB_PROXY_PORT="3128" \
  AGENT_LAB_EGRESS_SUBNET="$LAB_EGRESS_SUBNET" \
  AGENT_LAB_ALLOWED_TEST_DOMAIN="example.com" \
  AGENT_LAB_DIRECT_TEST_IP="1.1.1.1" \
  AGENT_LAB_EGRESS_ALLOWLIST="" \
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
  if [ -n "${LAB_PROJECT:-}" ] &&
     [ -n "${LAB_ENV_FILE:-}" ] &&
     [ -n "${LAB_COPY:-}" ] &&
     [ -d "$LAB_COPY" ]; then
    docker_test_compose --profile core --profile egress --profile agent --profile devtools \
      down --volumes --remove-orphans >/dev/null 2>&1 || true
  fi
  if [ -n "${LAB_WORK:-}" ] && [ -d "$LAB_WORK" ]; then
    rm -rf "$LAB_WORK"
  fi
  return 0
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
    "$LAB_DEVBOX_IMAGE_ID" \
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
    "$LAB_DEVBOX_IMAGE_ID" infinity >/dev/null
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
    "$LAB_DEVBOX_IMAGE_ID" \
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
