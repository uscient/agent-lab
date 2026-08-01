#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
# shellcheck source=scripts/lib/serena.sh
source "$repo_root/scripts/lib/serena.sh"
work="$(mktemp -d)"
cleanup() {
  find "$work" -xdev -depth -delete >/dev/null 2>&1 || true
}
trap cleanup EXIT
failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

require_text() {
  local file="$1" text="$2" label="$3"
  if grep -Fq -- "$text" "$repo_root/$file"; then
    pass "$label"
  else
    fail "$label"
  fi
}

require_absent() {
  local file="$1" pattern="$2" label="$3"
  if grep -Eq -- "$pattern" "$repo_root/$file"; then
    fail "$label"
  else
    pass "$label"
  fi
}

require_text .serena/project.yml 'project_name: "agent-lab-dev"' \
  "Serena project has an unambiguous logical name"
require_text .serena/project.yml 'language_servers:' \
  "Serena project uses the current language_servers schema"
require_text .serena/project.yml '- bash' \
  "Serena project selects the actual Bash language"
require_text .serena/project.yml 'language_backend: LSP' \
  "Serena project explicitly selects the LSP backend"
require_text .serena/project.yml 'ls_workspace_folders: ["."]' \
  "Serena indexes exactly the Agent Lab project root"

require_text compose.serena.yaml 'network_mode: none' \
  "Serena runtime has no network namespace"
require_text compose.serena.yaml 'read_only: true' \
  "Serena runtime root filesystem is read-only"
require_text compose.serena.yaml 'create_host_path: false' \
  "Serena project bind cannot create an unintended host path"
if [ "$(grep -Fc '          propagation: rprivate' \
        "$repo_root/compose.serena.yaml")" -eq 3 ] &&
   [ "$(grep -Fc '          recursive: disabled' \
        "$repo_root/compose.serena.yaml")" -eq 3 ]; then
  pass "Every base Serena bind is private and nonrecursive"
else
  fail "Every base Serena bind is private and nonrecursive"
fi
require_text compose.serena.yaml 'target: /workspace' \
  "Serena sees the stable container project root"
require_absent compose.serena.yaml \
  'docker\.sock|/run/agent-secrets|/home/[^:]*:|HTTP_PROXY|HTTPS_PROXY' \
  "Serena runtime has no socket, secret, home, or proxy mount"

require_text images/serena/Dockerfile \
  '6c1c9653700cbe644cb5a5b026b77db2f4071c36' \
  "Serena source is commit-pinned"
require_text images/serena/Dockerfile \
  'bash-language-server.version="5.6.0"' \
  "Bash language server version is recorded"
require_text images/serena/Dockerfile \
  'shellcheck.version="0.10.0"' \
  "ShellCheck version is recorded"
require_text images/serena/Dockerfile \
  '/opt/serena-assets/language_servers/static/BashLanguageServer/bash-lsp/shellcheck/' \
  "ShellCheck is preseeded in Serena's required managed layout"

require_text compose.serena.yaml 'SERENA_USAGE_REPORTING: "false"' \
  "Serena usage reporting is disabled"
require_text scripts/serena-mcp '--enable-web-dashboard false' \
  "Serena dashboard is disabled"
require_absent scripts/serena-mcp \
  '--project([=[:space:]]|$)|--project-from-cwd' \
  "Serena starts recoverably without a fixed project"

require_text .codex/config.toml '[mcp_servers.serena]' \
  "Codex registers Serena at project scope"
require_text .codex/config.toml \
  'command = "env"' \
  "Codex strips startup-file variables before invoking Bash"
require_text .codex/config.toml \
  'args = ["-u", "BASH_ENV", "-u", "ENV", "bash", "--noprofile", "--norc", "-c", "root=\"$(git rev-parse --show-toplevel)\" && exec \"$root/scripts/serena-mcp\" --context=codex"]' \
  "Codex uses a clean non-login Bash and discovers the repository root"
if jq -e '
  .mcpServers.serena.command == "env" and
  .mcpServers.serena.args == [
    "-u", "BASH_ENV", "-u", "ENV",
    "bash", "--noprofile", "--norc", "-c",
    "root=\"$(git rev-parse --show-toplevel)\" && exec \"$root/scripts/serena-mcp\" --context=claude-code"
  ]
' .mcp.json >/dev/null; then
  pass "Claude uses a clean non-login Bash and discovers the repository root"
else
  fail "Claude uses a clean non-login Bash and discovers the repository root"
fi
require_text .mcp.json \
  '"root=\"$(git rev-parse --show-toplevel)\" && exec \"$root/scripts/serena-mcp\" --context=claude-code"' \
  "Claude discovers the repository root before using its verified Serena context"
require_text .grok/config.toml '[mcp_servers.serena]' \
  "Grok registers Serena at project scope"
require_text .grok/config.toml \
  'command = "env"' \
  "Grok strips startup-file variables before invoking Bash"
require_text .grok/config.toml \
  'args = ["-u", "BASH_ENV", "-u", "ENV", "bash", "--noprofile", "--norc", "-c", "root=\"$(git rev-parse --show-toplevel)\" && exec \"$root/scripts/serena-mcp\" --context=grok"]' \
  "Grok uses a clean non-login Bash and discovers the repository root"

for excluded_tool in replace_in_files replace_content rename_symbol safe_delete_symbol; do
  require_text .serena/project.yml "- $excluded_tool" \
    "Serena excludes broad mutator $excluded_tool"
done
require_text .codex/hooks.json 'mcp__serena__replace_symbol_body' \
  "Codex guards Serena semantic mutators"
require_text .claude/settings.json 'mcp__serena__replace_symbol_body' \
  "Claude guards Serena semantic mutators"
require_text .grok/hooks/git-policy.json 'serena__replace_symbol_body' \
  "Grok guards Serena semantic mutators"

if agent_lab_serena_validate_identity 1002 1002 >/dev/null 2>&1 &&
   ! agent_lab_serena_validate_identity 0 1002 >/dev/null 2>&1 &&
   ! agent_lab_serena_validate_identity 1002 0 >/dev/null 2>&1 &&
   ! agent_lab_serena_validate_identity invalid 1002 >/dev/null 2>&1; then
  pass "Serena launcher accepts only canonical non-root UID/GID values"
else
  fail "Serena launcher accepts only canonical non-root UID/GID values"
fi

# Image identity, pin, and writable-volume metadata must come from one immutable
# Docker inspection snapshot. The launcher keeps distinct operator diagnostics for
# each rejected field and pins Compose to the inspected image ID on success.
fake_docker_bin="$work/fake-docker-bin"
mkdir -p "$fake_docker_bin" "$work/fake-home"
cat > "$fake_docker_bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${FAKE_DOCKER_LOG:?}"
case "${1:-}" in
  info)
    exit 0
    ;;
  image)
    [ "${2:-}" = inspect ] || exit 99
    if [ "${FAKE_IMAGE_MODE:-}" = missing ]; then
      exit 1
    fi
    if [ "${FAKE_IMAGE_MODE:-}" = inspect-error ]; then
      exit 42
    fi
    # The old launcher first performs one unformatted existence probe.
    [ "${3:-}" = --format ] || exit 0
    format="${4:-}"
    expected_format='{{json .Id}}{{println}}{{json (index .Config.Labels "org.agent-lab.serena.ref")}}{{println}}{{json (index .Config "Volumes")}}'
    if [ "$format" = "$expected_format" ]; then
      printf '%s\n%s\n%s\n' \
        "$(jq -Rn --arg value "${FAKE_IMAGE_ID:?}" '$value')" \
        "$(jq -Rn --arg value "${FAKE_IMAGE_REF:?}" '$value')" \
        "${FAKE_IMAGE_VOLUMES:?}"
    elif [ "$format" = '{{.Id}}' ]; then
      printf '%s\n' "${FAKE_IMAGE_ID:?}"
    elif [[ "$format" == *'org.agent-lab.serena.ref'* ]]; then
      printf '%s\n' "${FAKE_IMAGE_REF:?}"
    elif [[ "$format" == *'.Config.Volumes'* ]]; then
      printf '%s\n' "${FAKE_IMAGE_VOLUMES:?}"
    else
      exit 98
    fi
    ;;
  compose)
    if [ "${2:-}" = version ]; then
      exit 0
    fi
    printf 'ENV AGENT_LAB_SERENA_IMAGE=%s\n' \
      "${AGENT_LAB_SERENA_IMAGE-<unset>}" >> "${FAKE_DOCKER_LOG:?}"
    ;;
  *)
    exit 99
    ;;
esac
EOF
chmod +x "$fake_docker_bin/docker"

valid_image_id="sha256:$(printf '%064d' 0)"
run_serena_image_case() {
  local case_id="$1" expected_rc="$2" mode="$3" image_id="$4"
  local image_ref="$5" image_volumes="$6" marker="$7" expect_compose="$8"
  local case_dir="$work/image-$case_id" docker_log output rc inspect_count
  local formatted_count compose_seen=0 marker_seen=0 image_pin_seen=0 launch_ok=0
  mkdir -p "$case_dir"
  docker_log="$case_dir/docker.log"
  output="$case_dir/output"
  : > "$docker_log"
  rc=0
  env -i \
    PATH="$fake_docker_bin:/usr/bin:/bin" \
    HOME="$work/fake-home" \
    FAKE_DOCKER_LOG="$docker_log" \
    FAKE_IMAGE_MODE="$mode" \
    FAKE_IMAGE_ID="$image_id" \
    FAKE_IMAGE_REF="$image_ref" \
    FAKE_IMAGE_VOLUMES="$image_volumes" \
    COMPOSE_PROJECT_NAME="agent-lab-serena-metadata-$case_id" \
    "$repo_root/scripts/serena-mcp" --context=codex >"$output" 2>&1 || rc=$?

  inspect_count="$(grep -c '^image inspect' "$docker_log" || true)"
  formatted_count="$(grep -c '^image inspect --format ' "$docker_log" || true)"
  if grep -Eq '^compose --project-name ' "$docker_log"; then compose_seen=1; fi
  if [ -z "$marker" ] || grep -Fq -- "$marker" "$output"; then marker_seen=1; fi
  if grep -Fxq "ENV AGENT_LAB_SERENA_IMAGE=$valid_image_id" "$docker_log"; then
    image_pin_seen=1
  fi
  if { [ "$expect_compose" = yes ] && [ "$compose_seen" -eq 1 ] &&
       [ "$image_pin_seen" -eq 1 ]; } ||
     { [ "$expect_compose" = no ] && [ "$compose_seen" -eq 0 ]; }; then
    launch_ok=1
  fi

  if [ "$rc" -eq "$expected_rc" ] &&
     [ "$inspect_count" -eq 1 ] && [ "$formatted_count" -eq 1 ] &&
     [ "$marker_seen" -eq 1 ] && [ "$launch_ok" -eq 1 ]; then
    pass "Serena image metadata snapshot: $case_id"
  else
    fail "Serena image metadata snapshot: $case_id (rc=$rc inspect=$inspect_count formatted=$formatted_count compose=$compose_seen pin=$image_pin_seen)"
    sed 's/^/  /' "$output"
  fi
}

run_serena_image_case \
  missing 125 missing "$valid_image_id" "$AGENT_LAB_SERENA_REF" null \
  'Serena MCP: cannot inspect image metadata; image may be missing' no
run_serena_image_case \
  inspect-error 125 inspect-error "$valid_image_id" "$AGENT_LAB_SERENA_REF" null \
  'Serena MCP: cannot inspect image metadata; image may be missing' no
run_serena_image_case \
  invalid-id 125 present not-a-digest "$AGENT_LAB_SERENA_REF" null \
  'Serena MCP: Docker returned an invalid image identity' no
run_serena_image_case \
  wrong-ref 125 present "$valid_image_id" wrong-ref null \
  'Serena MCP: image does not match pinned Serena ref' no
run_serena_image_case \
  unexpected-volume 125 present "$valid_image_id" "$AGENT_LAB_SERENA_REF" \
  '{"/data":{}}' 'Serena MCP: image declares unexpected writable volumes' no
run_serena_image_case \
  injected-record 125 present "$valid_image_id" "$AGENT_LAB_SERENA_REF"$'\nnull' \
  '{"/data":{}}' 'Serena MCP: image does not match pinned Serena ref' no
run_serena_image_case \
  extra-record 125 present "$valid_image_id" "$AGENT_LAB_SERENA_REF" \
  $'null\nextra' 'Serena MCP: Docker returned malformed image metadata' no
run_serena_image_case \
  valid 0 present "$valid_image_id" "$AGENT_LAB_SERENA_REF" null '' yes

if grep -Eq '(^|[[:space:]])(mapfile|readarray)([[:space:]]|$)' \
     "$repo_root/scripts/serena-mcp"; then
  fail "Serena image metadata parser remains compatible with Bash 3.2 record readers"
else
  pass "Serena image metadata parser remains compatible with Bash 3.2 record readers"
fi

fixture="$work/project"
mount_state="$work/mount-state"
mkdir -p \
  "$fixture/.git" \
  "$fixture/policy" \
  "$fixture/.serena" \
  "$fixture/secrets" \
  "$fixture/cache" \
  "$fixture/proj" \
  "$fixture/src" \
  "$mount_state"
printf '%s\n' \
  'AGENTS.md' \
  'policy/' \
  '.mcp.json' \
  '.serena/project.yml' \
  > "$fixture/policy/protected.paths"
printf '%s\n' 'fixture rail' > "$fixture/AGENTS.md"
printf '%s\n' '{}' > "$fixture/.mcp.json"
printf '%s\n' 'project_name: fixture' > "$fixture/.serena/project.yml"
printf '%s\n' 'masked fixture value' > "$fixture/.env.local"
printf '%s\n' 'public example value' > "$fixture/.env.example"
printf '%s\n' '#!/usr/bin/env bash' > "$fixture/src/safe.sh"

mount_rc=0
agent_lab_serena_prepare_mounts \
  "$fixture" "$mount_state" >/dev/null 2>&1 || mount_rc=$?
if [ "$mount_rc" -eq 0 ] &&
   [ "$AGENT_LAB_SERENA_GIT_MASK_SOURCE" = "$mount_state/empty-dir" ] &&
   [ "$AGENT_LAB_SERENA_CACHE_DIR" = "$mount_state/project-cache" ] &&
   grep -Fq "target: '/workspace/.env.local'" \
     "$AGENT_LAB_SERENA_MOUNT_OVERRIDE" &&
   grep -Fq "target: '/workspace/secrets'" \
     "$AGENT_LAB_SERENA_MOUNT_OVERRIDE" &&
   grep -Fq "target: '/workspace/cache'" \
     "$AGENT_LAB_SERENA_MOUNT_OVERRIDE" &&
   grep -Fq "target: '/workspace/proj'" \
     "$AGENT_LAB_SERENA_MOUNT_OVERRIDE" &&
   grep -Fq "target: '/workspace/AGENTS.md'" \
     "$AGENT_LAB_SERENA_MOUNT_OVERRIDE" &&
   grep -Fq "target: '/workspace/policy'" \
     "$AGENT_LAB_SERENA_MOUNT_OVERRIDE" &&
   grep -Fq "target: '/workspace/.mcp.json'" \
     "$AGENT_LAB_SERENA_MOUNT_OVERRIDE" &&
   grep -Fq "target: '/workspace/.serena/project.yml'" \
     "$AGENT_LAB_SERENA_MOUNT_OVERRIDE" &&
   ! grep -Fq "target: '/workspace/.env.example'" \
     "$AGENT_LAB_SERENA_MOUNT_OVERRIDE" &&
   ! grep -Fq 'read_only: false' "$AGENT_LAB_SERENA_MOUNT_OVERRIDE" &&
   [ "$(grep -Fc '      - type: bind' \
        "$AGENT_LAB_SERENA_MOUNT_OVERRIDE")" -eq \
     "$(grep -Fc '          propagation: rprivate' \
        "$AGENT_LAB_SERENA_MOUNT_OVERRIDE")" ] &&
   [ "$(grep -Fc '      - type: bind' \
        "$AGENT_LAB_SERENA_MOUNT_OVERRIDE")" -eq \
     "$(grep -Fc '          recursive: disabled' \
        "$AGENT_LAB_SERENA_MOUNT_OVERRIDE")" ]; then
  pass "Serena mount plan masks local state and overlays every existing rail read-only"
else
  fail "Serena mount plan masks local state and overlays every existing rail read-only"
fi

mkdir -p "$fixture/src/same-device-bind"
mountinfo_fixture="$work/mountinfo"
mountinfo_error="$work/mountinfo-error"
printf '%s\n' \
  '25 1 0:42 / / rw,relatime - tmpfs tmpfs rw' \
  "26 25 0:42 /source $fixture/src/same-device-bind rw,relatime - tmpfs tmpfs rw" \
  > "$mountinfo_fixture"
mountinfo_rc=0
agent_lab_serena_reject_child_mounts \
  "$fixture" "$mountinfo_fixture" 2>"$mountinfo_error" ||
  mountinfo_rc=$?
if [ "$mountinfo_rc" -eq 125 ] &&
   grep -Fq \
     'refusing child mount exposed by the project bind' \
     "$mountinfo_error" &&
   grep -Fq '/workspace/src/same-device-bind' "$mountinfo_error"; then
  pass "Serena rejects a same-filesystem child bind from mount metadata"
else
  fail "Serena rejects a same-filesystem child bind from mount metadata"
fi

missing_cover_fixture="$work/mountinfo-missing-cover"
missing_cover_error="$work/mountinfo-missing-cover-error"
printf '%s\n' \
  '25 1 0:42 / /unrelated rw,relatime - tmpfs tmpfs rw' \
  > "$missing_cover_fixture"
missing_cover_rc=0
agent_lab_serena_reject_child_mounts \
  "$fixture" "$missing_cover_fixture" 2>"$missing_cover_error" ||
  missing_cover_rc=$?
if [ "$missing_cover_rc" -eq 125 ] &&
   grep -Fq \
     'process mount metadata does not cover the project root' \
     "$missing_cover_error"; then
  pass "Serena mount inspection fails closed without a covering mount"
else
  fail "Serena mount inspection fails closed without a covering mount"
fi

malformed_mountinfo="$work/mountinfo-malformed"
malformed_mountinfo_error="$work/mountinfo-malformed-error"
printf '%s\n' 'not mountinfo' > "$malformed_mountinfo"
malformed_mountinfo_rc=0
agent_lab_serena_reject_child_mounts \
  "$fixture" "$malformed_mountinfo" 2>"$malformed_mountinfo_error" ||
  malformed_mountinfo_rc=$?
if [ "$malformed_mountinfo_rc" -eq 125 ] &&
   grep -Fq 'process mount metadata is malformed' \
     "$malformed_mountinfo_error"; then
  pass "Serena mount inspection fails closed on malformed metadata"
else
  fail "Serena mount inspection fails closed on malformed metadata"
fi

live_bind_project="$work/live-bind-project"
live_bind_state="$work/live-bind-state"
live_bind_error="$work/live-bind-error"
mkdir -p \
  "$live_bind_project/.git" \
  "$live_bind_project/policy" \
  "$live_bind_project/source" \
  "$live_bind_project/child" \
  "$live_bind_state"
: > "$live_bind_project/policy/protected.paths"
if unshare --user --map-root-user --mount \
    bash --noprofile --norc -c '
      set -euo pipefail
      mount --make-rprivate /
      mount --bind "$1/source" "$1/child"
      umount "$1/child"
    ' _ "$live_bind_project" >/dev/null 2>&1; then
  if unshare --user --map-root-user --mount \
      bash --noprofile --norc -c '
        set -euo pipefail
        mount --make-rprivate /
        source "$1"
        mount --bind "$2/source" "$2/child"
        rc=0
        agent_lab_serena_prepare_mounts "$2" "$3" \
          >/dev/null 2>"$4" || rc=$?
        [ "$rc" -eq 125 ]
        grep -Fq "refusing child mount exposed by the project bind" "$4"
        grep -Fq "/workspace/child" "$4"
      ' _ "$repo_root/scripts/lib/serena.sh" "$live_bind_project" \
        "$live_bind_state" "$live_bind_error"; then
    pass "Serena rejects a live same-filesystem child bind mount"
  else
    fail "Serena rejects a live same-filesystem child bind mount"
  fi
else
  printf '%s\n' \
    'INFO live child-bind probe unavailable; synthetic same-device case remains mandatory'
fi

find "$fixture/secrets" -depth -delete
mkdir -p "$work/outside"
ln -s "$work/outside" "$fixture/secrets"
symlink_state="$work/symlink-state"
mkdir "$symlink_state"
symlink_rc=0
agent_lab_serena_prepare_mounts \
  "$fixture" "$symlink_state" >/dev/null 2>&1 || symlink_rc=$?
if [ "$symlink_rc" -eq 125 ]; then
  pass "Serena mount planning fails closed on a sensitive symlink"
else
  fail "Serena mount planning fails closed on a sensitive symlink"
fi
find "$fixture/secrets" -depth -delete

mkdir -p "$fixture/src/private"
printf '%s\n' 'synthetic fixture' > "$fixture/src/private/service.key"
nested_state="$work/nested-state"
mkdir "$nested_state"
nested_rc=0
agent_lab_serena_prepare_mounts \
  "$fixture" "$nested_state" >/dev/null 2>&1 || nested_rc=$?
if [ "$nested_rc" -eq 125 ]; then
  pass "Serena mount planning rejects nested credential and key paths"
else
  fail "Serena mount planning rejects nested credential and key paths"
fi

find "$fixture/src/private" -depth -delete
mkdir -p "$fixture/vendor/component"
: > "$fixture/vendor/component/.git"
nested_git_state="$work/nested-git-state"
nested_git_error="$work/nested-git-error"
mkdir "$nested_git_state"
nested_git_rc=0
agent_lab_serena_prepare_mounts \
  "$fixture" "$nested_git_state" >/dev/null 2>"$nested_git_error" ||
  nested_git_rc=$?
if [ "$nested_git_rc" -eq 125 ] &&
   grep -Fq \
     'refusing nested .git object exposed at /workspace/vendor/component/.git' \
     "$nested_git_error"; then
  pass "Serena mount planning rejects a visible nested .git object"
else
  fail "Serena mount planning rejects a visible nested .git object"
fi

require_text compose.serena.yaml \
  'source: ${AGENT_LAB_SERENA_GIT_MASK_SOURCE:?set by scripts/serena-mcp}' \
  "Compose requires the generated Git metadata mask"
require_text compose.serena.yaml \
  'target: /workspace/.serena/cache' \
  "Compose gives Serena a private project-cache mount"
require_text scripts/serena-mcp \
  '-f "$AGENT_LAB_SERENA_MOUNT_OVERRIDE"' \
  "launcher always applies the generated containment override"

printf 'SUMMARY failures=%s\n' "$failures"
test "$failures" -eq 0
