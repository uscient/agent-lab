#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
# shellcheck source=scripts/lib/serena.sh
source "$repo_root/scripts/lib/serena.sh"
project_name="agent-lab-serena-gate-$$"
mount_probe_container=""
mount_probe_work=""
failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

cleanup() {
  if [ -n "$mount_probe_container" ]; then
    docker rm -f "$mount_probe_container" >/dev/null 2>&1 || true
  fi
  if [[ "$mount_probe_work" == /tmp/agent-lab-serena-runtime.* ]] &&
     [ -d "$mount_probe_work" ] &&
     [ ! -L "$mount_probe_work" ]; then
    find "$mount_probe_work" -xdev -depth -delete >/dev/null 2>&1 || true
  fi
  AGENT_LAB_SERENA_IMAGE="agent-lab/serena:cleanup" \
  AGENT_LAB_SERENA_PROJECT_DIR="$repo_root" \
  AGENT_LAB_SERENA_GIT_MASK_SOURCE="$repo_root/.git" \
  AGENT_LAB_SERENA_CACHE_DIR="$repo_root/.serena/cache" \
  AGENT_LAB_SERENA_UID="$(id -u)" \
  AGENT_LAB_SERENA_GID="$(id -g)" \
    docker compose \
      --project-name "$project_name" \
      --env-file /dev/null \
      -f "$repo_root/compose.serena.yaml" \
      --profile serena \
      down --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

COMPOSE_PROJECT_NAME="$project_name" "$repo_root/scripts/dev/serena-build"

mount_probe_work="$(mktemp -d /tmp/agent-lab-serena-runtime.XXXXXX)"
probe_project="$mount_probe_work/project"
probe_state="$mount_probe_work/mount-state"
mkdir -p \
  "$probe_project/.git" \
  "$probe_project/policy" \
  "$probe_project/.serena/cache" \
  "$probe_project/secrets" \
  "$probe_project/cache" \
  "$probe_project/proj" \
  "$probe_project/src" \
  "$probe_state"
printf '%s\n' \
  'AGENTS.md' \
  'policy/' \
  '.mcp.json' \
  '.serena/project.yml' \
  'compose.serena.yaml' \
  > "$probe_project/policy/protected.paths"
printf '%s\n' 'fixture rail' > "$probe_project/AGENTS.md"
printf '%s\n' '{}' > "$probe_project/.mcp.json"
printf '%s\n' 'project_name: fixture' > "$probe_project/.serena/project.yml"
printf '%s\n' 'services: {}' > "$probe_project/compose.serena.yaml"
printf '%s\n' 'masked fixture value' > "$probe_project/.env.local"
printf '%s\n' '#!/usr/bin/env bash' > "$probe_project/src/safe.sh"

agent_lab_serena_prepare_mounts "$probe_project" "$probe_state"
probe_image="$(
  docker image inspect --format '{{.Id}}' "$AGENT_LAB_SERENA_TAG"
)"
mount_probe_container="$(
  AGENT_LAB_SERENA_IMAGE="$probe_image" \
  AGENT_LAB_SERENA_PROJECT_DIR="$probe_project" \
  AGENT_LAB_SERENA_UID="$(id -u)" \
  AGENT_LAB_SERENA_GID="$(id -g)" \
    docker compose \
      --project-name "$project_name" \
      --env-file /dev/null \
      -f "$repo_root/compose.serena.yaml" \
      -f "$AGENT_LAB_SERENA_MOUNT_OVERRIDE" \
      run \
      -d \
      --no-deps \
      --name "$project_name-mount-probe" \
      --entrypoint /bin/bash \
      serena \
      -c 'while :; do sleep 60; done'
)"

probe_inspect="$mount_probe_work/inspect.json"
docker inspect "$mount_probe_container" > "$probe_inspect"
if jq -e \
    --arg project "$probe_project" \
    --arg cache "$probe_state/project-cache" \
    --arg git_mask "$probe_state/empty-dir" \
    '
      .[0].Mounts as $mounts
      | ([ $mounts[] | select(.RW == true) | .Destination ] | sort)
          == ["/workspace", "/workspace/.serena/cache"]
        and any($mounts[];
          .Destination == "/workspace"
          and .Source == $project
          and .RW == true)
        and any($mounts[];
          .Destination == "/workspace/.serena/cache"
          and .Source == $cache
          and .RW == true)
        and any($mounts[];
          .Destination == "/workspace/.git"
          and .Source == $git_mask
          and .RW == false)
        and all(
          "/workspace/.env.local",
          "/workspace/secrets",
          "/workspace/cache",
          "/workspace/proj",
          "/workspace/AGENTS.md",
          "/workspace/policy",
          "/workspace/.mcp.json",
          "/workspace/.serena/project.yml",
          "/workspace/compose.serena.yaml";
          . as $target
          | any($mounts[];
              .Destination == $target and .RW == false)
        )
    ' "$probe_inspect" >/dev/null; then
  pass "live Serena mounts mask Git/local state, protect rails, and isolate cache"
else
  fail "live Serena mounts mask Git/local state, protect rails, and isolate cache"
fi

if docker exec "$mount_probe_container" \
     bash -c 'printf "%s\n" "safe-edit" >> /workspace/src/safe.sh' &&
   grep -Fq 'safe-edit' "$probe_project/src/safe.sh"; then
  pass "ordinary project source remains writable"
else
  fail "ordinary project source remains writable"
fi

if ! docker exec "$mount_probe_container" \
       bash -c 'printf "%s\n" "blocked" >> /workspace/AGENTS.md' \
       >/dev/null 2>&1 &&
   ! docker exec "$mount_probe_container" \
       bash -c 'touch /workspace/.git/write-probe' \
       >/dev/null 2>&1 &&
   ! docker exec "$mount_probe_container" \
       bash -c 'touch /workspace/secrets/write-probe' \
       >/dev/null 2>&1 &&
   docker exec "$mount_probe_container" \
       bash -c 'test ! -s /workspace/.env.local' &&
   docker exec "$mount_probe_container" \
       bash -c 'test -z "$(find /workspace/.git -mindepth 1 -print -quit)"'; then
  pass "masked state is empty and read-only while protected rails reject writes"
else
  fail "masked state is empty and read-only while protected rails reject writes"
fi

if docker exec "$mount_probe_container" \
     bash -c 'printf "%s\n" "cache" > /workspace/.serena/cache/write-probe' &&
   [ -f "$probe_state/project-cache/write-probe" ] &&
   [ ! -e "$probe_project/.serena/cache/write-probe" ]; then
  pass "Serena project cache writes stay in private temporary state"
else
  fail "Serena project cache writes stay in private temporary state"
fi

docker rm -f "$mount_probe_container" >/dev/null
mount_probe_container=""

COMPOSE_PROJECT_NAME="$project_name" "$repo_root/scripts/dev/serena-smoke"

printf 'SUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
