#!/usr/bin/env bash
set -euo pipefail

# Docker-free contract checks for the strict runtime gate and isolated test lifecycle.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
gate="$repo_root/scripts/dev/security-gate"
fast_manifest="$repo_root/tests/security/fast.manifest"
docker_manifest="$repo_root/tests/security/docker.manifest"
docker_lib="$repo_root/tests/docker/lib.sh"
docker_gate="$repo_root/scripts/dev/docker-gate"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

project="$(
  COMPOSE_PROJECT_NAME="agent-lab-contract-fixture" \
    bash -c 'source "$1/scripts/common"; printf "%s" "$PROJECT_NAME"' _ "$repo_root"
)"
if [ "$project" = "agent-lab-contract-fixture" ]; then
  pass "Compose project names are caller-isolated"
else
  fail "Compose project names are caller-isolated"
fi

if grep -Fq 'com.docker.network.bridge.gateway_mode_ipv4: isolated' \
     "$repo_root/compose.yaml"; then
  pass "agent bridge requests isolated gateway mode"
else
  fail "agent bridge requests isolated gateway mode"
fi

expected_suites="$work/expected-docker-suites"
cat > "$expected_suites" <<'EOF'
image-volume tests/docker/image-volume.sh SUMMARY failures=0
wrapper-context-runtime tests/docker/wrapper-context.sh SUMMARY failures=0
network-boundary tests/docker/network-boundary.sh SUMMARY failures=0
dns-contract tests/docker/dns-contract.sh SUMMARY failures=0
runtime-inspect-differential tests/docker/runtime-inspect-differential.sh SUMMARY failures=0
runtime-hardening tests/docker/runtime-hardening.sh RUNTIME HARDENING SUMMARY failures=0
security-fixture tests/docker/security-fixture.sh DOCKER SECURITY FIXTURE SUMMARY failures=0
secret-nondisclosure tests/docker/secret-nondisclosure.sh SUMMARY failures=0
serena-runtime tests/docker/serena-runtime.sh SERENA RUNTIME SUMMARY failures=0
EOF
actual_suites="$work/actual-docker-suites"
awk '$1 == "suite" { $1 = ""; sub(/^ /, ""); print }' "$docker_manifest" > "$actual_suites"
if cmp -s "$expected_suites" "$actual_suites"; then
  pass "versioned Docker gate has the exact required suite contract"
else
  fail "versioned Docker gate has the exact required suite contract"
  diff -u "$expected_suites" "$actual_suites" || true
fi

serena_runtime="$repo_root/tests/docker/serena-runtime.sh"
if [ "$(grep -Fxc "printf 'SERENA RUNTIME SUMMARY failures=%s\\n' \"\$failures\"" "$serena_runtime")" -eq 1 ] &&
   ! grep -Fq "printf 'SUMMARY failures=%s\\n' \"\$failures\"" "$serena_runtime"; then
  pass "Serena runtime owns one suite-specific completion marker"
else
  fail "Serena runtime owns one suite-specific completion marker"
fi

runtime_hardening="$repo_root/tests/docker/runtime-hardening.sh"
if [ "$(grep -Fxc "printf 'RUNTIME HARDENING SUMMARY failures=%s\\n' \"\$failures\"" "$runtime_hardening")" -eq 1 ] &&
   ! grep -Fq "printf 'SUMMARY failures=%s\\n' \"\$failures\"" "$runtime_hardening"; then
  pass "runtime hardening owns one suite-specific completion marker"
else
  fail "runtime hardening owns one suite-specific completion marker"
fi
if grep -Fxq 'tool python3' "$fast_manifest" &&
   ! grep -Fxq 'tool timeout' "$fast_manifest" &&
   grep -Fxq 'tool python3' "$docker_manifest" &&
   grep -Fxq 'tool timeout' "$docker_manifest"; then
  pass "Python is explicit for both gates while timeout stays Docker-only"
else
  fail "Python is explicit for both gates while timeout stays Docker-only"
fi

if [ -x "$docker_gate" ] &&
   grep -Fq "docker buildx build \\" "$docker_gate" &&
   grep -Fq "docker build \\" "$docker_gate" &&
   grep -Fq 'AGENT_LAB_RUNTIME_INSPECT_BACKEND=python' "$docker_gate" &&
   grep -Fq './scripts/dev/security-gate docker || gate_rc=$?' "$docker_gate" &&
   grep -Fq 'exit "$gate_rc"' "$docker_gate"; then
  pass "canonical Docker replay builds the devbox before running the strict gate"
else
  fail "canonical Docker replay builds the devbox before running the strict gate"
fi
if grep -Fq 'AGENT_LAB_DEVBOX_PREBUILT' "$docker_gate" &&
   grep -Fq 'docker image inspect' "$docker_gate" &&
   grep -Fq 'TIMING devbox-' "$docker_gate" &&
   grep -Fq 'TIMING docker-suites=' "$docker_gate"; then
  pass "CI prebuilt mode is verified and Docker phase timings are observable"
else
  fail "CI prebuilt mode is verified and Docker phase timings are observable"
fi
if grep -Eq \
     '^FROM debian:bookworm-slim@sha256:[0-9a-f]{64}$' \
     "$repo_root/images/devbox/Dockerfile"; then
  pass "canonical devbox base is content-pinned"
else
  fail "canonical devbox base is content-pinned"
fi

security_fixture="$repo_root/tests/docker/security-fixture.sh"
if [ -x "$security_fixture" ] &&
   grep -Fq 'docker image inspect --format' "$security_fixture" &&
   grep -Fq -- '--network none' "$security_fixture" &&
   grep -Fq -- '--read-only' "$security_fixture" &&
   grep -Fq -- '--tmpfs /tmp:rw,nosuid,nodev,noexec,size=16m' "$security_fixture" &&
   grep -Fq -- '--cap-drop ALL' "$security_fixture" &&
   grep -Fq -- '--security-opt no-new-privileges' "$security_fixture" &&
   grep -Fq -- '--user 1000:1000' "$security_fixture" &&
   grep -Fq -- '"$image_id" -c' "$security_fixture" &&
   ! grep -Eq -- '--privileged|--network (host|container:)|docker\.sock' \
     "$security_fixture"; then
  pass "simple Docker fixture is content-pinned and least-privilege"
else
  fail "simple Docker fixture is content-pinned and least-privilege"
fi
if grep -Fxq 'tests/docker/security-fixture.sh' \
     "$repo_root/policy/protected.paths"; then
  pass "simple Docker fixture is maintenance-protected"
else
  fail "simple Docker fixture is maintenance-protected"
fi
# Requested runtime flags only describe intent; the fixture must also observe the
# kernel-enforced result of each one from inside the container.
if grep -Fq -- 'check test "$(id -u)" = 1000' "$security_fixture" &&
   grep -Fq -- 'check test "$(id -g)" = 1000' "$security_fixture" &&
   grep -Fq -- 'NoNewPrivs:/ { print \$2 }" /proc/self/status)" = 1' \
     "$security_fixture" &&
   grep -Fq -- '/sys/class/net' "$security_fixture" &&
   grep -Fq -- '" = lo' "$security_fixture" &&
   grep -Fq -- 'DOCKER SECURITY FIXTURE SUMMARY failures=%s' "$security_fixture" &&
   grep -Fq -- 'test "$failures" -eq 0' "$security_fixture"; then
  pass "simple Docker fixture proves its uid, no-new-privileges, and network containment"
else
  fail "simple Docker fixture proves its uid, no-new-privileges, and network containment"
fi
# A non-root process reports CapEff=0 and cannot write to root-owned `/` whether or
# not --cap-drop ALL and --read-only were requested, so neither observable can carry
# that evidence. Only the capability bounding set and the root mount options change
# when those flags are dropped.
if grep -Fq -- 'CapBnd:/ { print \$2 }" /proc/self/status)" = 0000000000000000' \
     "$security_fixture" &&
   grep -Fq -- 'check grep -Eq "^[0-9]+ [0-9]+ [0-9]+:[0-9]+ [^ ]+ / ro[, ]" /proc/self/mountinfo' \
     "$security_fixture" &&
   grep -Fq -- 'check touch /tmp/agent-lab-tmp-write-probe' "$security_fixture"; then
  pass "simple Docker fixture proves read-only root and dropped capabilities independently of its uid"
else
  fail "simple Docker fixture proves read-only root and dropped capabilities independently of its uid"
fi

docker_gate_fixture="$work/docker-gate-fixture"
docker_gate_bin="$work/docker-gate-bin"
mkdir -p \
  "$docker_gate_fixture/scripts/dev" \
  "$docker_gate_fixture/scripts/lib" \
  "$docker_gate_bin"
cp "$docker_gate" "$docker_gate_fixture/scripts/dev/docker-gate"
cp \
  "$repo_root/scripts/lib/dev-common.sh" \
  "$docker_gate_fixture/scripts/lib/dev-common.sh"
git -C "$docker_gate_fixture" init -q

cat > "$docker_gate_fixture/scripts/dev/security-gate" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_SECURITY_GATE_LOG:?}"
printf 'runtime-inspect-backend=%s\n' \
  "${AGENT_LAB_RUNTIME_INSPECT_BACKEND-<unset>}" >> "${FAKE_SECURITY_GATE_LOG:?}"
printf 'FAKE SECURITY GATE rc=%s\n' "${FAKE_SECURITY_GATE_RC:-0}"
exit "${FAKE_SECURITY_GATE_RC:-0}"
EOF
chmod +x "$docker_gate_fixture/scripts/dev/security-gate"

cat > "$docker_gate_bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_DOCKER_LOG:?}"
case "${1:-} ${2:-}" in
  "info ") exit "${FAKE_DOCKER_INFO_RC:-0}" ;;
  "compose version") exit "${FAKE_DOCKER_COMPOSE_RC:-0}" ;;
  "image inspect") exit "${FAKE_DOCKER_INSPECT_RC:-0}" ;;
  "build "*|"buildx build") exit "${FAKE_DOCKER_BUILD_RC:-0}" ;;
  "buildx version") exit "${FAKE_DOCKER_BUILDX_RC:-0}" ;;
  *) exit 99 ;;
esac
EOF
chmod +x "$docker_gate_bin/docker"

run_docker_gate_fixture() {
  local prebuilt_mode="$1"
  local inspect_rc="${2:-0}"
  local security_gate_rc="${3:-0}"

  : > "$work/docker-gate-docker.log"
  : > "$work/docker-gate-security.log"
  docker_gate_fixture_rc=0
  docker_gate_fixture_out="$(
    cd "$docker_gate_fixture"
    PATH="$docker_gate_bin:$PATH" \
    GITHUB_ACTIONS='' \
    AGENT_LAB_DEVBOX_PREBUILT="$prebuilt_mode" \
    FAKE_DOCKER_LOG="$work/docker-gate-docker.log" \
    FAKE_DOCKER_INFO_RC=0 \
    FAKE_DOCKER_COMPOSE_RC=0 \
    FAKE_DOCKER_INSPECT_RC="$inspect_rc" \
    FAKE_DOCKER_BUILD_RC=0 \
    FAKE_SECURITY_GATE_LOG="$work/docker-gate-security.log" \
    FAKE_SECURITY_GATE_RC="$security_gate_rc" \
      ./scripts/dev/docker-gate 2>&1
  )" || docker_gate_fixture_rc=$?
}

run_docker_gate_fixture 0
if [ "$docker_gate_fixture_rc" -eq 0 ] &&
   grep -Fxq \
     'build -t agent-lab/devbox:local -f images/devbox/Dockerfile .' \
     "$work/docker-gate-docker.log" &&
   ! grep -Eq '^(image inspect|buildx build)( |$)' \
     "$work/docker-gate-docker.log" &&
   grep -Fxq 'docker' "$work/docker-gate-security.log" &&
   grep -Fxq 'runtime-inspect-backend=python' \
     "$work/docker-gate-security.log" &&
   printf '%s\n' "$docker_gate_fixture_out" |
     grep -Fq 'TIMING devbox-local-build='; then
  pass "Docker gate mode 0 builds before running the security suites"
else
  fail "Docker gate mode 0 builds before running the security suites"
fi

run_docker_gate_fixture 1
if [ "$docker_gate_fixture_rc" -eq 0 ] &&
   grep -Fxq 'image inspect agent-lab/devbox:local' \
     "$work/docker-gate-docker.log" &&
   ! grep -Eq '^(build|buildx build)( |$)' \
     "$work/docker-gate-docker.log" &&
   grep -Fxq 'docker' "$work/docker-gate-security.log" &&
   printf '%s\n' "$docker_gate_fixture_out" |
     grep -Fq 'TIMING devbox-prebuilt-verify='; then
  pass "Docker gate mode 1 inspects the prebuilt image and never builds"
else
  fail "Docker gate mode 1 inspects the prebuilt image and never builds"
fi

run_docker_gate_fixture 1 1
if [ "$docker_gate_fixture_rc" -eq 125 ] &&
   printf '%s\n' "$docker_gate_fixture_out" |
     grep -Fq 'cache-aware CI build did not load agent-lab/devbox:local' &&
   [ ! -s "$work/docker-gate-security.log" ] &&
   ! grep -Eq '^(build|buildx build)( |$)' \
     "$work/docker-gate-docker.log"; then
  pass "missing prebuilt image is infrastructure failure and runs no suite"
else
  fail "missing prebuilt image is infrastructure failure and runs no suite"
fi

run_docker_gate_fixture invalid
if [ "$docker_gate_fixture_rc" -eq 125 ] &&
   printf '%s\n' "$docker_gate_fixture_out" |
     grep -Fq 'AGENT_LAB_DEVBOX_PREBUILT must be 0 or 1' &&
   [ ! -s "$work/docker-gate-security.log" ] &&
   ! grep -Eq '^(image inspect|build|buildx build)( |$)' \
     "$work/docker-gate-docker.log"; then
  pass "invalid prebuilt mode is infrastructure failure and runs no suite"
else
  fail "invalid prebuilt mode is infrastructure failure and runs no suite"
fi

run_docker_gate_fixture 1 0 37
if [ "$docker_gate_fixture_rc" -eq 37 ] &&
   grep -Fxq 'docker' "$work/docker-gate-security.log" &&
   printf '%s\n' "$docker_gate_fixture_out" |
     grep -Fq 'FAKE SECURITY GATE rc=37' &&
   printf '%s\n' "$docker_gate_fixture_out" |
     tail -n 1 |
     grep -Eq '^TIMING docker-suites=[0-9]+s total=[0-9]+s$'; then
  pass "Docker gate preserves suite failure after reporting phase timings"
else
  fail "Docker gate preserves suite failure after reporting phase timings"
fi

# shellcheck source=tests/docker/lib.sh
source "$docker_lib"

pin_fixture="$work/compose.pin.yaml"
cat > "$pin_fixture" <<'EOF'
services:
  fixture:
    image: example/fixture:mutable
EOF
if docker_test_pin_compose_image \
     "$pin_fixture" "example/fixture:mutable" \
     "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" &&
   grep -Fxq \
     '    image: sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
     "$pin_fixture"; then
  pass "Compose image pinning replaces exactly one mutable reference"
else
  fail "Compose image pinning replaces exactly one mutable reference"
fi

duplicate_fixture="$work/compose.duplicate.yaml"
cat > "$duplicate_fixture" <<'EOF'
services:
  first:
    image: example/fixture:mutable
  second:
    image: example/fixture:mutable
EOF
duplicate_before="$work/compose.duplicate.before.yaml"
cp "$duplicate_fixture" "$duplicate_before"
duplicate_rc=0
docker_test_pin_compose_image \
  "$duplicate_fixture" "example/fixture:mutable" \
  "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
  >/dev/null 2>&1 || duplicate_rc=$?
if [ "$duplicate_rc" -eq 125 ] &&
   cmp -s "$duplicate_before" "$duplicate_fixture"; then
  pass "Compose image pinning fails closed on ambiguous references"
else
  fail "Compose image pinning fails closed on ambiguous references"
fi

if grep -Fxq 'ARG AGENT_LAB_DEVBOX_IMAGE=agent-lab/devbox:local' \
     "$repo_root/tests/egress/Dockerfile" &&
   grep -Fxq 'FROM ${AGENT_LAB_DEVBOX_IMAGE}' \
     "$repo_root/tests/egress/Dockerfile" &&
   grep -Fq -- \
     '--build-arg "AGENT_LAB_DEVBOX_IMAGE=${LAB_DEVBOX_PINNED_REF}"' \
     "$docker_lib" &&
   grep -Fq \
     'source_key="${devbox_digest}-${dockerfile_hash}-${cases_hash}-${dockerignore_hash}"' \
     "$docker_lib" &&
   grep -Fq \
     'LAB_EGRESS_TEST_IMAGE_REF="agent-lab/egress-test:gate-${source_digest}"' \
     "$docker_lib"; then
  pass "offline probe build is keyed by every build input and uses the captured devbox"
else
  fail "offline probe build is keyed by every build input and uses the captured devbox"
fi

if ! grep -Fq 'agent-lab/devbox:local' \
     "$repo_root/tests/docker/image-volume.sh" \
     "$repo_root/tests/docker/secret-nondisclosure.sh" \
     "$repo_root/tests/docker/wrapper-context.sh"; then
  pass "runtime evidence uses captured image identities instead of the mutable devbox tag"
else
  fail "runtime evidence uses captured image identities instead of the mutable devbox tag"
fi

if ! grep -Eq 'docker_test_compose .*build|docker (pull|build)' \
     "$repo_root/tests/docker/network-boundary.sh" \
     "$repo_root/tests/docker/dns-contract.sh"; then
  pass "containment suites perform no late image build or pull"
else
  fail "containment suites perform no late image build or pull"
fi

cleanup_order_ok=1
for suite_path in \
  tests/docker/image-volume.sh \
  tests/docker/wrapper-context.sh \
  tests/docker/network-boundary.sh \
  tests/docker/dns-contract.sh \
  tests/docker/runtime-hardening.sh \
  tests/docker/secret-nondisclosure.sh; do
  trap_line="$(
    awk '$0 == "trap docker_test_cleanup EXIT" { print NR; exit }' \
      "$repo_root/$suite_path"
  )"
  init_line="$(
    awk '/^docker_test_init / { print NR; exit }' "$repo_root/$suite_path"
  )"
  if [ -z "$trap_line" ] ||
     [ -z "$init_line" ] ||
     [ "$trap_line" -ge "$init_line" ]; then
    cleanup_order_ok=0
  fi
done
if [ "$cleanup_order_ok" -eq 1 ]; then
  pass "every runtime suite installs cleanup before fallible initialization"
else
  fail "every runtime suite installs cleanup before fallible initialization"
fi

abandoned_fixture="$work/abandoned-init"
mkdir -p "$abandoned_fixture/repo"
LAB_WORK="$abandoned_fixture"
LAB_COPY="$abandoned_fixture/repo"
LAB_ENV_FILE="$abandoned_fixture/agent.env"
docker_test_abandon_init
if [ ! -e "$abandoned_fixture" ] &&
   [ -z "$LAB_WORK" ] &&
   [ -z "$LAB_COPY" ] &&
   [ -z "$LAB_ENV_FILE" ]; then
  pass "failed image preflight abandons its temporary fixture"
else
  fail "failed image preflight abandons its temporary fixture"
fi

mkdir -p "$work/bin"
cat > "$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  "info ") exit "${FAKE_DOCKER_INFO_RC:-0}" ;;
  "compose version") exit "${FAKE_DOCKER_COMPOSE_RC:-0}" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$work/bin/docker"

cat > "$work/fixture.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'executed\n' >> "${FAKE_SUITE_LOG:?}"
printf 'PASS docker fixture\n'
EOF
chmod +x "$work/fixture.sh"
cat > "$work/docker.manifest" <<EOF
tool bash
suite fixture $work/fixture.sh PASS docker fixture
EOF

run_fixture_gate() {
  local info_rc="$1" compose_rc="$2" rc=0
  : > "$work/suite.log"
  fixture_out="$(
    PATH="$work/bin:$PATH" \
    FAKE_DOCKER_INFO_RC="$info_rc" \
    FAKE_DOCKER_COMPOSE_RC="$compose_rc" \
    FAKE_SUITE_LOG="$work/suite.log" \
      "$gate" docker --manifest "$work/docker.manifest" 2>&1
  )" || rc=$?
  fixture_rc="$rc"
}

run_fixture_gate 1 0
if [ "$fixture_rc" -eq 125 ] &&
   printf '%s\n' "$fixture_out" | grep -Fq 'Docker daemon is unavailable' &&
   [ ! -s "$work/suite.log" ]; then
  pass "Docker daemon failure is infrastructure and executes no suite"
else
  fail "Docker daemon failure is infrastructure and executes no suite"
fi

run_fixture_gate 0 1
if [ "$fixture_rc" -eq 125 ] &&
   printf '%s\n' "$fixture_out" | grep -Fq 'Docker Compose v2 is unavailable' &&
   [ ! -s "$work/suite.log" ]; then
  pass "Compose failure is infrastructure and executes no suite"
else
  fail "Compose failure is infrastructure and executes no suite"
fi

run_fixture_gate 0 0
if [ "$fixture_rc" -eq 0 ] &&
   printf '%s\n' "$fixture_out" | grep -Fq 'SECURITY GATE PASS' &&
   grep -Fxq 'executed' "$work/suite.log"; then
  pass "healthy Docker prerequisites execute the required suite"
else
  fail "healthy Docker prerequisites execute the required suite"
fi

printf 'SUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
