#!/usr/bin/env bash
set -euo pipefail

# Docker-free contract checks for the strict runtime gate and isolated test lifecycle.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
gate="$repo_root/scripts/dev/security-gate"
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
image-volume tests/docker/image-volume.sh
wrapper-context-runtime tests/docker/wrapper-context.sh
network-boundary tests/docker/network-boundary.sh
dns-contract tests/docker/dns-contract.sh
runtime-hardening tests/docker/runtime-hardening.sh
secret-nondisclosure tests/docker/secret-nondisclosure.sh
EOF
actual_suites="$work/actual-docker-suites"
awk '$1 == "suite" { print $2, $3 }' "$docker_manifest" > "$actual_suites"
if cmp -s "$expected_suites" "$actual_suites"; then
  pass "versioned Docker gate has the exact required suite contract"
else
  fail "versioned Docker gate has the exact required suite contract"
  diff -u "$expected_suites" "$actual_suites" || true
fi

if [ -x "$docker_gate" ] &&
   grep -Fq "docker buildx build \\" "$docker_gate" &&
   grep -Fq "docker build \\" "$docker_gate" &&
   grep -Fq 'exec ./scripts/dev/security-gate docker' "$docker_gate"; then
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
