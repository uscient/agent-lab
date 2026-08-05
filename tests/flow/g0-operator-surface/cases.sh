#!/usr/bin/env bash
# G0 operator-surface focused suite.
#
# Every assertion drives the public root ./lab boundary and nothing else.  The
# suite never imports product internals and never reimplements, duplicates, or
# weakens the existing verified onboarding oracle:
#
#   * installation identity is proved by equivalence against the reference
#     identity the existing scripts/agent-lab directory install path produces
#     for the same fixture,
#   * the durable effect a successful add is allowed to have is likewise the
#     effect that same existing path is observed to produce, compared as a path
#     set rather than as a hand-written allow-list, and
#   * durable no-effect claims are proved with lib/boundary-digest.py, which is
#     calibrated below before any scenario relies on it.
#
# No-effect claims are not PATH claims.  Every product invocation runs inside a
# calibrated effect sandbox that (a) resolves every PATH name through a
# deny-by-default recording dispatcher, (b) binds a recording shim over the
# *resolved absolute binary* of every effect tool present on the host, so an
# absolute argv[0] is trapped too, and (c) unshares the network namespace, so no
# Broker or registry contact can succeed and a decoy loopback endpoint proves
# the isolation is real rather than assumed.  The sandbox is proved not to
# obstruct legitimate work by running the whole existing verified onboarding
# path inside it during calibration.
#
# Exactly one primary public-boundary assertion is emitted per contract
# scenario, in the frozen order; helper checks corroborate that primary and
# never own a scenario on their own.
#
# Exit contract: 0 with the final marker when every assertion passes, 1 on
# assertion failure, 125 on setup, harness, or calibration uncertainty.
set -u -o pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
repo_root="$(cd -- "$script_dir/../../.." >/dev/null 2>&1 && pwd)"
lab="$repo_root/lab"
agent_lab="$repo_root/scripts/agent-lab"
bounded_helper="$repo_root/tests/helpers/run-bounded.py"
fixture="$repo_root/tests/experiment/fixtures/directories/minimal"
digest_tool="$script_dir/lib/boundary-digest.py"
cue_tool_dir="$repo_root/.cache/dev/tools/cue"
cedar_tool_dir="$repo_root/.cache/dev/tools/cedar"
expected_count=14
canary_secret='G0CANARYSECRET7f3a1c9e5b2d4086'
work=""
observed=""
failures=0
infrastructure=0
decoy_pid=""

# The frozen assertion identities, in the frozen emission order.
expected_ids=(
  WF-CLI-HELP
  SEC-CLI-USAGE
  WF-HOME-INIT
  WF-HOME-SELECT
  SEC-HOME-UNSAFE
  SEC-HOME-INCOMPATIBLE
  REC-HOME-UNCERTAIN
  WF-ADD-INSTALL
  WF-ADD-RETRY
  SEC-ADD-COLLISION
  REC-ADD-INTERRUPTED
  SEC-NAME-ABSENT
  WF-READ-NONMUTATING
  SEC-OUTPUT-SECRETS
)

stop_decoy() {
  if [ -n "$decoy_pid" ]; then
    kill "$decoy_pid" 2>/dev/null || true
    wait "$decoy_pid" 2>/dev/null || true
    decoy_pid=""
  fi
}

cleanup_work() {
  local failed=0
  stop_decoy
  if [ -n "$work" ] && [ -e "$work" ]; then
    # Installed Experiment envelopes are published read-only by design, and a
    # fault-injection fixture may leave a FIFO behind.
    find "$work" -type d -exec chmod u+rwx {} + 2>/dev/null || failed=1
    find "$work" -type f -exec chmod u+rw {} + 2>/dev/null || failed=1
    find "$work" -type f -delete 2>/dev/null || failed=1
    find "$work" -type l -delete 2>/dev/null || failed=1
    find "$work" -type p -delete 2>/dev/null || failed=1
    find "$work" -type s -delete 2>/dev/null || failed=1
    find "$work" -depth -type d -exec rmdir {} + 2>/dev/null || failed=1
    [ ! -e "$work" ] || failed=1
  fi
  return "$failed"
}

finish() {
  local assertions=0
  if [ -n "$observed" ] && [ -f "$observed" ]; then
    assertions="$(wc -l < "$observed")"
  fi
  if ! cleanup_work; then
    infrastructure=1
  fi
  trap - EXIT
  printf 'SUMMARY assertions=%s expected=%s failures=%s infra=%s\n' \
    "$assertions" "$expected_count" "$failures" "$infrastructure"
  if [ "$infrastructure" -ne 0 ]; then
    exit 125
  fi
  if [ "$failures" -ne 0 ]; then
    exit 1
  fi
  printf 'FLOW G0 OPERATOR SURFACE PASS\n'
}

infra_stop() {
  printf 'INFRA %s\n' "$1" >&2
  infrastructure=1
  finish
}

if ! work="$(mktemp -d)"; then
  printf 'SUMMARY assertions=0 expected=%s failures=0 infra=1\n' "$expected_count"
  exit 125
fi
trap 'cleanup_work >/dev/null 2>&1 || true' EXIT
observed="$work/observed"
: > "$observed"

pass() {
  printf 'PASS %s %s\n' "$1" "$2"
  printf '%s\n' "$1" >> "$observed"
}

fail() {
  printf 'FAIL %s %s\n' "$1" "$2"
  printf '%s\n' "$1" >> "$observed"
  failures=$((failures + 1))
}

# ---------------------------------------------------------------------------
# Prerequisites.  The root ./lab entrypoint is deliberately NOT a prerequisite:
# its absence is an assertion result, not a setup failure.  bwrap is required
# because without it the absolute-path trap and the network canary cannot be
# built, and a no-effect claim that can only see PATH-resolved names is not the
# claim the contract makes.
# ---------------------------------------------------------------------------

if [ ! -f "$bounded_helper" ] || [ ! -x "$agent_lab" ] || [ ! -d "$fixture" ] \
   || [ ! -f "$digest_tool" ] || [ ! -d "$cue_tool_dir" ] || [ ! -d "$cedar_tool_dir" ] \
   || ! command -v python3 >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 \
   || ! command -v mkfifo >/dev/null 2>&1 || ! command -v stat >/dev/null 2>&1 \
   || ! command -v bwrap >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
  infra_stop 'g0 operator-surface prerequisites are unavailable (python3, jq, mkfifo, stat, bwrap, timeout)'
fi
if ! python3 -I -B "$bounded_helper" --self-test >/dev/null 2>&1; then
  infra_stop 'bounded command helper self-test failed'
fi

# ---------------------------------------------------------------------------
# Bounded capture.  Every product invocation is time-bounded and fully reaped
# through the existing verified helper, so a hung facade is uncertainty rather
# than a wedged suite.  Barriers and fault injection replace sleeps throughout.
# ---------------------------------------------------------------------------

CAPTURE_OUT=""
CAPTURE_ERR=""
CAPTURE_RC=0

capture() {
  local label="$1"
  local status="$work/$label.status"
  local status_line=""
  shift
  CAPTURE_OUT="$work/$label.out"
  CAPTURE_ERR="$work/$label.err"
  CAPTURE_RC=0
  find "$status" -delete 2>/dev/null || true
  python3 -I -B "$bounded_helper" \
    --timeout 5 --status "$status" --stdout "$CAPTURE_OUT" --stderr "$CAPTURE_ERR" \
    -- "$@" || CAPTURE_RC=$?
  if [ -f "$status" ]; then
    status_line="$(cat "$status")"
  fi
  if [ "$status_line" != "child:$CAPTURE_RC" ]; then
    printf 'INFRA bounded command status is inconsistent: %s rc=%s status=%s\n' \
      "$label" "$CAPTURE_RC" "$status_line" >&2
    infrastructure=1
    CAPTURE_RC=125
  fi
}

# ---------------------------------------------------------------------------
# Boundary instruments.
# ---------------------------------------------------------------------------

digest_of() {
  # The strict instrument, including timestamps: the right question for a
  # command that claimed to have had no effect at all.  `cache` is recorded but
  # not descended into, because pinned-tool provisioning writes there routinely
  # and would mask real durable drift behind unrelated churn.
  python3 -I -B "$digest_tool" "$1" cache 2>/dev/null || printf 'digest-error\n'
}

durable_digest_of() {
  # Content, type, mode, ownership, links, device, inode, and size, but not
  # timestamps: the right question for an idempotent republication that may
  # legitimately re-apply an already-correct mode.
  python3 -I -B "$digest_tool" --durable "$1" cache 2>/dev/null || printf 'digest-error\n'
}

paths_of() {
  # The shape of a boundary: which entries exist, of which kind, at which mode.
  # Two boundaries that received the same durable effect compare equal here even
  # though their inodes and bytes differ.  The byte collation is pinned because
  # these listings are compared with comm.
  if ! python3 -I -B "$digest_tool" --paths "$1" cache 2>/dev/null \
       | LC_ALL=C sort > "$2"; then
    printf 'paths-error\n' > "$2"
  fi
}

path_identity() { stat -c '%d:%i' "$1" 2>/dev/null || printf 'no-identity\n'; }

bounded_output() {
  # Operator-facing text stays small enough to read in a terminal.
  local path="$1"
  local max_bytes="$2"
  local max_lines="$3"
  local bytes lines
  bytes="$(wc -c < "$path" 2>/dev/null || printf '999999')"
  lines="$(wc -l < "$path" 2>/dev/null || printf '999999')"
  [ "$bytes" -le "$max_bytes" ] && [ "$lines" -le "$max_lines" ]
}

private_boundary_ok() {
  # Every durable directory owner-owned and 0700; every durable regular file
  # owner-owned with no group or world bit.  The `cache` component is checked
  # but not descended into, exactly as the digest instruments treat it: pinned
  # tool provisioning copies public tool trees there with their own modes, and
  # the existing verified path itself leaves cache/tools group-readable, so
  # descending would reject a faithful implementation for tool churn.
  python3 -I -B - "$1" <<'PY'
from __future__ import annotations

import os
from pathlib import Path
import stat
import sys

root = Path(sys.argv[1])
if not root.is_dir():
    raise SystemExit(1)
uid = os.getuid()
for current, directories, files in os.walk(root):
    here = Path(current)
    metadata = here.lstat()
    if metadata.st_uid != uid or stat.S_IMODE(metadata.st_mode) != 0o700:
        raise SystemExit(1)
    if here == root / "cache":
        directories[:] = []
        continue
    for name in files:
        child_metadata = (here / name).lstat()
        if not stat.S_ISREG(child_metadata.st_mode):
            continue
        if child_metadata.st_uid != uid:
            raise SystemExit(1)
        if stat.S_IMODE(child_metadata.st_mode) & 0o077:
            raise SystemExit(1)
raise SystemExit(0)
PY
}

authority_ok() {
  # "init succeeded" has to mean a compatible closed home receipt was actually
  # published.  The frozen contract names the existing agent-lab.config/v0alpha1
  # and agent-lab.home/v0alpha1 closed receipt as the only G0-compatible durable
  # home metadata, so an owner-private empty tree is not a selected home.  Both
  # authority files are opened O_NOFOLLOW and required to be unaliased regular
  # files at mode 0600, which is also the shape the existing verified path
  # publishes, so this demands nothing that path does not already do.
  python3 -I -B - "$1" <<'PY'
from __future__ import annotations

import json
import os
from pathlib import Path
import stat
import sys

root = Path(sys.argv[1])
uid = os.getuid()
required = {
    "config.json": ("agent-lab.config/v0alpha1", ("paths",)),
    "home.json": ("agent-lab.home/v0alpha1", ("configDigest", "locks", "paths")),
}
for name, (api_version, keys) in required.items():
    try:
        descriptor = os.open(root / name, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError:
        raise SystemExit(1)
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise SystemExit(1)
        if metadata.st_uid != uid or stat.S_IMODE(metadata.st_mode) != 0o600:
            raise SystemExit(1)
        if metadata.st_nlink != 1:
            raise SystemExit(1)
        payload = os.read(descriptor, 1 << 20)
    finally:
        os.close(descriptor)
    try:
        value = json.loads(payload)
    except ValueError:
        raise SystemExit(1)
    if not isinstance(value, dict) or value.get("apiVersion") != api_version:
        raise SystemExit(1)
    for key in keys:
        if key not in value:
            raise SystemExit(1)
raise SystemExit(0)
PY
}

# ---------------------------------------------------------------------------
# Effect canaries.
#
# Three independent channels, because a facade that causes a real effect does
# not have to go looking for it on PATH:
#
#   1. a deny-by-default PATH dispatcher shadowing every executable name the
#      host exposes, so an unexpected tool is recorded and refused rather than
#      silently permitted because nobody thought to name it,
#   2. a recording shim bound over the resolved absolute binary of every effect
#      tool that exists, so /usr/bin/docker is trapped as surely as `docker`,
#   3. a private network namespace plus a decoy loopback endpoint, so no Broker
#      or registry contact can succeed and the isolation itself is proved.
# ---------------------------------------------------------------------------

base_path="$PATH"
deny_dir="$work/deny"
trap_dir="$work/trap"
canary_log="$work/canary.log"
allow_log="$work/allowed.log"
decoy_log="$work/decoy.log"
mkdir -p "$deny_dir/bin" "$trap_dir" || infra_stop 'effect canary directories could not be created'
: > "$canary_log"
: > "$allow_log"
: > "$decoy_log"

effect_tools=(
  docker docker-compose docker-credential-desktop podman buildah skopeo oras
  nerdctl ctr crictl kubectl helm systemctl systemd-run service
  curl wget nc ncat netcat socat telnet ssh scp sftp rsync
  git svn hg apt apt-get yum dnf apk brew pip pip3 npm npx pnpm yarn cargo go
)

# Tools a faithful implementation may legitimately use.  The list is not a
# guess: the whole existing verified onboarding path is run under this
# dispatcher during calibration below, so anything it genuinely needs is proved
# to be permitted before any scenario depends on the deny-by-default rule.
allow_names='python3:python3.12:python3.11:python3.10:python:sh:bash:dash:env:cat:cp:mv:ln:mkdir:rmdir:rm:chmod:stat:sed:awk:gawk:mawk:grep:egrep:fgrep:find:sort:uniq:comm:cmp:diff:head:tail:wc:tr:cut:dirname:basename:readlink:realpath:mktemp:date:touch:test:true:false:sync:tar:gzip:gunzip:zcat:unzip:file:id:uname:getent:locale:od:xxd:sleep:expr:seq:df:du:ls:cue:cedar'

cat > "$deny_dir/dispatch" <<EOF
#!/bin/sh
# Deny-by-default tool dispatcher for the G0 operator-surface suite.  Every
# invocation is recorded.  Allow-listed names are forwarded to the real binary;
# everything else is refused, so an effect tool nobody enumerated is still
# caught.  Log destinations are baked in rather than read from the environment,
# so a facade that scrubs its child environment cannot silence the canary.
name="\${0##*/}"
host_path='$base_path'
case ":$allow_names:" in
  *":\$name:"*)
    printf '%s %s\n' "\$name" "\$*" >> '$allow_log'
    real=''
    IFS=:
    for dir in \$host_path; do
      if [ -x "\$dir/\$name" ] && [ ! -d "\$dir/\$name" ]; then
        real="\$dir/\$name"
        break
      fi
    done
    unset IFS
    if [ -n "\$real" ]; then
      exec "\$real" "\$@"
    fi
    ;;
esac
printf '%s %s\n' "\$name" "\$*" >> '$canary_log'
exit 97
EOF
chmod 0755 "$deny_dir/dispatch" || infra_stop 'deny-by-default dispatcher could not be armed'

old_ifs="$IFS"
IFS=':'
read -r -a path_entries <<< "$base_path"
IFS="$old_ifs"
for path_entry in "${path_entries[@]}"; do
  [ -n "$path_entry" ] && [ -d "$path_entry" ] || continue
  for candidate in "$path_entry"/*; do
    [ -f "$candidate" ] && [ -x "$candidate" ] || continue
    candidate_name="${candidate##*/}"
    [ -e "$deny_dir/bin/$candidate_name" ] \
      || ln -s "$deny_dir/dispatch" "$deny_dir/bin/$candidate_name" \
      || infra_stop 'deny-by-default dispatcher could not shadow a PATH name'
  done
done
for effect_tool in "${effect_tools[@]}" g0-unexpected-tool; do
  [ -e "$deny_dir/bin/$effect_tool" ] \
    || ln -s "$deny_dir/dispatch" "$deny_dir/bin/$effect_tool" \
    || infra_stop 'deny-by-default dispatcher could not shadow an effect tool'
done

# Absolute-path traps.  One recording shim per effect tool, bound over the
# tool's resolved binary inside the sandbox, so an absolute argv[0] cannot slip
# past the PATH dispatcher.
sandbox_binds=()
trapped_real=""
trap_probe_real=""
trap_probe_name=""
for effect_tool in "${effect_tools[@]}"; do
  tool_path="$(command -v "$effect_tool" 2>/dev/null)" || continue
  [ -n "$tool_path" ] || continue
  tool_real="$(readlink -f "$tool_path" 2>/dev/null)" || continue
  [ -n "$tool_real" ] && [ -f "$tool_real" ] || continue
  case ":$trapped_real:" in
    *":$tool_real:"*) continue ;;
  esac
  trapped_real="$trapped_real:$tool_real"
  {
    printf '#!/bin/sh\n'
    printf 'printf "%%s %%s\\n" "%s" "$*" >> %s\n' "$effect_tool" "'$canary_log'"
    printf 'exit 97\n'
  } > "$trap_dir/$effect_tool" || infra_stop 'absolute-path trap shim could not be written'
  chmod 0755 "$trap_dir/$effect_tool" || infra_stop 'absolute-path trap shim could not be armed'
  sandbox_binds+=(--bind "$trap_dir/$effect_tool" "$tool_real")
  if [ -z "$trap_probe_real" ]; then
    trap_probe_real="$tool_real"
    trap_probe_name="$effect_tool"
  fi
done
if [ -z "$trap_probe_real" ]; then
  infra_stop 'no effect tool is present to calibrate the absolute-path trap against'
fi

sandbox_prefix=(bwrap --die-with-parent --dev-bind / / "${sandbox_binds[@]}" --unshare-net --)

# The decoy Broker endpoint: a loopback listener in the host network namespace.
# It proves the namespace isolation is real, and any accepted connection is
# itself a recorded effect.
decoy_script="$work/decoy-broker.py"
decoy_port_fifo="$work/decoy.port"
cat > "$decoy_script" <<'PY'
"""A decoy Broker endpoint on loopback.

Publishes its port through a FIFO, so the suite synchronizes on a barrier
rather than on a clock, answers each accepted connection with a byte so the
client knows the connection was already recorded, and expires on its own.
"""

from __future__ import annotations

import socket
import sys
import time

port_fifo, log_path, lifetime = sys.argv[1], sys.argv[2], float(sys.argv[3])
server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", 0))
server.listen(16)
with open(port_fifo, "w", encoding="ascii") as handle:
    handle.write(f"{server.getsockname()[1]}\n")
server.settimeout(0.25)
deadline = time.monotonic() + lifetime
while time.monotonic() < deadline:
    try:
        connection, _ = server.accept()
    except OSError:
        continue
    with open(log_path, "a", encoding="ascii") as handle:
        handle.write("connection\n")
    try:
        connection.sendall(b"ok")
    except OSError:
        pass
    connection.close()
PY
mkfifo "$decoy_port_fifo" || infra_stop 'decoy endpoint barrier could not be created'
python3 -I -B "$decoy_script" "$decoy_port_fifo" "$decoy_log" 300 >/dev/null 2>&1 &
decoy_pid=$!
decoy_port="$(timeout 20 head -n 1 "$decoy_port_fifo" 2>/dev/null || printf '')"
if [ -z "$decoy_port" ]; then
  infra_stop 'decoy Broker endpoint did not publish a port'
fi

connect_probe() {
  # Prints CONNECT-OK only when the decoy answered, which happens strictly
  # after the connection was recorded.
  python3 -I -B - "$1" <<'PY'
from __future__ import annotations

import socket
import sys

probe = socket.socket()
probe.settimeout(5)
try:
    probe.connect(("127.0.0.1", int(sys.argv[1])))
    if probe.recv(2) == b"ok":
        print("CONNECT-OK")
    else:
        print("CONNECT-SHORT")
except OSError as error:
    print(f"CONNECT-BLOCKED {error.errno}")
PY
}

canary_clean() { [ ! -s "$canary_log" ] && [ ! -s "$decoy_log" ]; }
canary_reset() { : > "$canary_log"; : > "$decoy_log"; }

sandbox_env=(
  "PATH=$deny_dir/bin"
  "AGENT_LAB_CUE_TOOL_DIR=$cue_tool_dir"
  "AGENT_LAB_CEDAR_TOOL_DIR=$cedar_tool_dir"
)

# --- canary calibration ----------------------------------------------------
# A no-effect claim is only worth what its canaries can see, so each channel is
# proved to record a real invocation before any scenario relies on it.

capture calibrate-path-effect "${sandbox_prefix[@]}" env "${sandbox_env[@]}" docker calibration
grep -q '^docker ' "$canary_log" || infra_stop 'PATH effect canary calibration failed'
: > "$canary_log"

capture calibrate-absolute-effect "${sandbox_prefix[@]}" env "${sandbox_env[@]}" \
  "$trap_probe_real" calibration
grep -q "^$trap_probe_name " "$canary_log" \
  || infra_stop 'absolute-path effect trap calibration failed; no-effect claims would be vacuous'
: > "$canary_log"

capture calibrate-unknown-tool "${sandbox_prefix[@]}" env "${sandbox_env[@]}" \
  g0-unexpected-tool calibration
[ "$CAPTURE_RC" -eq 97 ] || infra_stop 'deny-by-default dispatcher did not refuse an unknown tool'
grep -q '^g0-unexpected-tool ' "$canary_log" \
  || infra_stop 'deny-by-default dispatcher did not record an unknown tool'
: > "$canary_log"

capture calibrate-allowed-tool "${sandbox_prefix[@]}" env "${sandbox_env[@]}" \
  python3 -c 'raise SystemExit(0)'
if [ "$CAPTURE_RC" -ne 0 ] || ! canary_clean; then
  infra_stop 'deny-by-default dispatcher refuses a legitimately needed tool'
fi

if [ "$(connect_probe "$decoy_port")" != 'CONNECT-OK' ]; then
  infra_stop 'decoy Broker endpoint is not reachable; the network canary would be vacuous'
fi
[ -s "$decoy_log" ] || infra_stop 'decoy Broker endpoint did not record a real connection'
: > "$decoy_log"

connect_script="$work/connect-probe.py"
cat > "$connect_script" <<'PY'
"""Attempt one connection to the decoy Broker endpoint and report the outcome."""

from __future__ import annotations

import socket
import sys

probe = socket.socket()
probe.settimeout(5)
try:
    probe.connect(("127.0.0.1", int(sys.argv[1])))
    print("CONNECT-OK")
except OSError as error:
    print(f"CONNECT-BLOCKED {error.errno}")
PY
capture calibrate-network "${sandbox_prefix[@]}" env "${sandbox_env[@]}" \
  python3 -I -B "$connect_script" "$decoy_port"
grep -q '^CONNECT-BLOCKED ' "$CAPTURE_OUT" \
  || infra_stop 'sandboxed network namespace did not isolate the decoy endpoint'
canary_clean || infra_stop 'network canary recorded a connection during calibration'

# Calibrate both digest instruments.  Each must observe a one-byte content
# change and a mode-only change, and must report an absent boundary as absent.
# The strict instrument must additionally observe a timestamp-only touch and the
# durable instrument must ignore exactly that, or the two would not be distinct
# and one of them would be answering the wrong question.
calibration_root="$work/digest-calibration"
mkdir -p "$calibration_root/child" || infra_stop 'digest calibration root unavailable'
printf 'one\n' > "$calibration_root/child/file"
chmod 0600 "$calibration_root/child/file"
strict_before="$(digest_of "$calibration_root")"
durable_before="$(durable_digest_of "$calibration_root")"
paths_of "$calibration_root" "$work/calibration-paths-before"
printf 'two\n' > "$calibration_root/child/file"
strict_bytes="$(digest_of "$calibration_root")"
durable_bytes="$(durable_digest_of "$calibration_root")"
paths_of "$calibration_root" "$work/calibration-paths-bytes"
chmod 0644 "$calibration_root/child/file"
strict_mode="$(digest_of "$calibration_root")"
durable_mode="$(durable_digest_of "$calibration_root")"
paths_of "$calibration_root" "$work/calibration-paths-mode"
touch -d '2001-02-03 04:05:06' "$calibration_root/child/file" \
  || infra_stop 'digest calibration touch unavailable'
strict_touch="$(digest_of "$calibration_root")"
durable_touch="$(durable_digest_of "$calibration_root")"
calibration_absent="$(digest_of "$work/never-created")"
durable_absent="$(durable_digest_of "$work/never-created")"
if [ "$strict_before" = 'digest-error' ] || [ "$durable_before" = 'digest-error' ] \
   || [ "$strict_before" = "$strict_bytes" ] || [ "$durable_before" = "$durable_bytes" ] \
   || [ "$strict_bytes" = "$strict_mode" ] || [ "$durable_bytes" = "$durable_mode" ] \
   || [ "$strict_mode" = "$strict_touch" ] || [ "$durable_mode" != "$durable_touch" ] \
   || [ "$calibration_absent" != 'absent' ] || [ "$durable_absent" != 'absent' ]; then
  infra_stop 'boundary digest calibration failed; no-effect claims would be vacuous'
fi
# The path instrument must ignore content, observe a mode change, and observe a
# new entry, or an "exactly this durable effect" claim would be unfalsifiable.
printf 'extra\n' > "$calibration_root/child/added"
paths_of "$calibration_root" "$work/calibration-paths-added"
if ! cmp -s "$work/calibration-paths-before" "$work/calibration-paths-bytes" \
   || cmp -s "$work/calibration-paths-bytes" "$work/calibration-paths-mode" \
   || cmp -s "$work/calibration-paths-mode" "$work/calibration-paths-added"; then
  infra_stop 'boundary path-set calibration failed; durable effect claims would be vacuous'
fi

# Calibrate the bounded-output predicate so a size claim cannot be vacuous.
printf 'short\n' > "$work/calibration-small"
head -c 4097 /dev/zero | tr '\0' 'x' > "$work/calibration-large"
if ! bounded_output "$work/calibration-small" 4096 60 \
   || bounded_output "$work/calibration-large" 4096 60; then
  infra_stop 'bounded output calibration failed'
fi

# ---------------------------------------------------------------------------
# Facade invocation.  Ambient HOME is always a decoy, so selection precedence
# is provable rather than incidental, and every product invocation runs inside
# the calibrated effect sandbox.
# ---------------------------------------------------------------------------

decoy_home="$work/decoy-ambient-home"
mkdir -p "$decoy_home" || infra_stop 'decoy ambient home unavailable'

lab_home_env=""

lab_environment() {
  # `env` refuses options after the first assignment operand, so -u leads.
  lab_env_args=(env)
  if [ -z "$lab_home_env" ]; then
    lab_env_args+=(-u AGENT_LAB_HOME)
  fi
  lab_env_args+=(
    "${sandbox_env[@]}"
    "HOME=$decoy_home"
    "AGENT_LAB_TEST_CANARY_SECRET=$canary_secret"
  )
  if [ -n "$lab_home_env" ]; then
    lab_env_args+=("AGENT_LAB_HOME=$lab_home_env")
  fi
}

lab_env_args=()

lab_run() {
  local label="$1"
  shift
  lab_environment
  capture "$label" "${sandbox_prefix[@]}" "${lab_env_args[@]}" "$lab" "$@"
}

oracle_env=(
  env -u AGENT_LAB_HOME
  "AGENT_LAB_CUE_TOOL_DIR=$cue_tool_dir"
  "AGENT_LAB_CEDAR_TOOL_DIR=$cedar_tool_dir"
)

oracle_run() {
  local label="$1"
  shift
  capture "$label" "${oracle_env[@]}" "$agent_lab" "$@"
}

sandboxed_oracle_run() {
  local label="$1"
  shift
  capture "$label" "${sandbox_prefix[@]}" env -u AGENT_LAB_HOME "${sandbox_env[@]}" \
    "$agent_lab" "$@"
}

lab_present() { [ -f "$lab" ] && [ -x "$lab" ]; }

ready_home() {
  # A ready selected home, published only by the existing verified path.  The
  # frozen contract names the existing agent-lab.config/v0alpha1 and
  # agent-lab.home/v0alpha1 receipt as the only G0-compatible durable metadata,
  # so the facade is required to accept exactly this boundary.
  local target="$1"
  local label="$2"
  oracle_run "$label" --home "$target" init
  [ "$CAPTURE_RC" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Reference identity and reference durable effect, both from the existing
# verified onboarding path.  This is equivalence against the existing oracle,
# not a second oracle.
# ---------------------------------------------------------------------------

oracle_home="$work/oracle-home"
ready_home "$oracle_home" oracle-init || infra_stop 'reference home initialization failed'
authority_ok "$oracle_home" \
  || infra_stop 'the existing verified path did not publish the expected closed home receipt'
paths_of "$oracle_home" "$work/oracle-before.paths"
oracle_run oracle-check --home "$oracle_home" experiment check "$fixture"
[ "$CAPTURE_RC" -eq 0 ] || infra_stop 'reference Experiment check failed'
oracle_run oracle-authorize --home "$oracle_home" experiment authorize install "$fixture"
[ "$CAPTURE_RC" -eq 0 ] || infra_stop 'reference authorization failed'
oracle_run oracle-install --home "$oracle_home" experiment install "$fixture"
[ "$CAPTURE_RC" -eq 0 ] || infra_stop 'reference directory installation failed'
oracle_name="$(jq -r '.name // empty' "$CAPTURE_OUT" 2>/dev/null)"
oracle_key="$(jq -r '.installationKey // empty' "$CAPTURE_OUT" 2>/dev/null)"
oracle_receipt="$(jq -r '.receiptDigest // empty' "$CAPTURE_OUT" 2>/dev/null)"
if [ -z "$oracle_name" ] || [ -z "$oracle_key" ] || [ -z "$oracle_receipt" ]; then
  infra_stop 'reference installation identity is unavailable'
fi
paths_of "$oracle_home" "$work/oracle-after.paths"
# The reference durable effect of onboarding one directory into a ready home:
# whatever the existing verified path itself adds, and nothing else.  A facade
# that also prepares or activates cannot match this set, and a facade that
# genuinely delegates cannot fail it.
LC_ALL=C comm -13 "$work/oracle-before.paths" "$work/oracle-after.paths" \
  > "$work/reference-added.paths"
LC_ALL=C comm -23 "$work/oracle-before.paths" "$work/oracle-after.paths" \
  > "$work/reference-removed.paths"
if [ ! -s "$work/reference-added.paths" ] || [ -s "$work/reference-removed.paths" ]; then
  infra_stop 'reference install effect could not be characterized'
fi

# The sandbox must not be able to reject a faithful implementation, so the whole
# existing verified onboarding path is run inside it and must produce the same
# identity with no canary hit at all.
sandbox_home="$work/sandbox-adequacy-home"
canary_reset
sandboxed_oracle_run sandbox-init --home "$sandbox_home" init
[ "$CAPTURE_RC" -eq 0 ] || infra_stop 'effect sandbox obstructs the existing verified home publication'
sandboxed_oracle_run sandbox-check --home "$sandbox_home" experiment check "$fixture"
[ "$CAPTURE_RC" -eq 0 ] || infra_stop 'effect sandbox obstructs the existing verified check path'
sandboxed_oracle_run sandbox-install --home "$sandbox_home" experiment install "$fixture"
[ "$CAPTURE_RC" -eq 0 ] || infra_stop 'effect sandbox obstructs the existing verified install path'
if [ "$(jq -r '.installationKey // empty' "$CAPTURE_OUT" 2>/dev/null)" != "$oracle_key" ]; then
  infra_stop 'effect sandbox changed the result of the existing verified install path'
fi
canary_clean || infra_stop 'effect sandbox reports an effect for the existing verified path'

# A genuinely distinct installation identity under the same Experiment name.
conflict_source="$work/conflict-source"
mkdir -p "$conflict_source" || infra_stop 'conflict source unavailable'
sed 's/sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/' \
  "$fixture/experiment.cue" > "$conflict_source/experiment.cue" \
  || infra_stop 'conflict source could not be derived'
if cmp -s "$fixture/experiment.cue" "$conflict_source/experiment.cue"; then
  infra_stop 'conflict source is not a distinct installation identity'
fi

# A genuine interrupted publication intent, produced by killing the existing
# verified path at a barrier on its own staging boundary rather than by
# fabricating residue.  This is the positive control for reconciliation: the
# contract requires an exact retry to reconcile a recognized interrupted intent,
# not to refuse every boundary that is not pristine.
interrupted_home=""
build_interrupted_intent() {
  local attempt candidate staging install_pid spins entries envelopes
  for attempt in 1 2 3 4 5; do
    candidate="$work/interrupted-home-$attempt"
    ready_home "$candidate" "interrupted-init-$attempt" || continue
    staging="$candidate/experiments/.staging"
    "${oracle_env[@]}" "$agent_lab" --home "$candidate" experiment install "$fixture" \
      >/dev/null 2>&1 &
    install_pid=$!
    spins=0
    while kill -0 "$install_pid" 2>/dev/null; do
      if [ -e "$staging/experiment-install" ]; then
        kill -9 "$install_pid" 2>/dev/null || true
        break
      fi
      spins=$((spins + 1))
      if [ "$spins" -gt 200000 ]; then
        kill -9 "$install_pid" 2>/dev/null || true
        break
      fi
    done
    wait "$install_pid" 2>/dev/null || true
    entries="$(find "$staging" -mindepth 1 2>/dev/null | wc -l)"
    envelopes="$(find "$candidate/experiments" -mindepth 1 -maxdepth 1 -type d \
      ! -name '.staging' 2>/dev/null | wc -l)"
    if [ "$entries" -ge 1 ] && [ "$envelopes" -eq 0 ]; then
      interrupted_home="$candidate"
      return 0
    fi
  done
  return 1
}
build_interrupted_intent \
  || infra_stop 'a genuine interrupted publication intent could not be constructed'

account_home="$(python3 -I -B -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')/.agent-lab"

reclaim_account_probe() {
  # The account-database default is by definition outside any temporary
  # boundary.  If a defective facade created it during a read probe, the owning
  # assertion has already failed; remove only the empty directories the probe
  # caused so no residue is left in an operator's home.
  local before="$1"
  if [ "$before" = absent ] && [ -d "$account_home" ]; then
    find "$account_home" -depth -type d -exec rmdir {} + 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# WF-CLI-HELP -- e2e
# ---------------------------------------------------------------------------

scenario_wf_cli_help() {
  local id='WF-CLI-HELP'
  local text='root ./lab entrypoint exists and is executable'
  local help_home="$work/help-home"
  if ! lab_present; then
    fail "$id" "$text"
    return
  fi
  canary_reset
  lab_home_env="$help_home"
  lab_run help-no-arguments
  lab_home_env=""
  if [ "$CAPTURE_RC" -eq 0 ] \
     && [ -s "$CAPTURE_OUT" ] \
     && [ ! -s "$CAPTURE_ERR" ] \
     && bounded_output "$CAPTURE_OUT" 4096 60 \
     && grep -Fq './lab serve' "$CAPTURE_OUT" \
     && [ "$(grep -ic 'terminal' "$CAPTURE_OUT")" -ge 2 ] \
     && grep -Eq '(^|[^a-z])add([^a-z]|$)' "$CAPTURE_OUT" \
     && grep -Eq '(^|[^a-z])status([^a-z]|$)' "$CAPTURE_OUT" \
     && [ ! -e "$help_home" ] \
     && canary_clean; then
    pass "$id" "$text"
  else
    fail "$id" "$text"
  fi
}

# ---------------------------------------------------------------------------
# SEC-CLI-USAGE -- e2e
# ---------------------------------------------------------------------------

usage_ok=1
usage_index=0

usage_case() {
  local label="usage-$usage_index"
  usage_index=$((usage_index + 1))
  lab_run "$label" "$@"
  if [ "$CAPTURE_RC" -ne 2 ]; then
    usage_ok=0
    return
  fi
  # Concise bounded usage on the denial channel; stdout stays empty.
  if [ -s "$CAPTURE_OUT" ] || [ ! -s "$CAPTURE_ERR" ]; then
    usage_ok=0
    return
  fi
  if ! bounded_output "$CAPTURE_ERR" 2048 20; then
    usage_ok=0
    return
  fi
  if ! grep -Fqi 'usage' "$CAPTURE_ERR"; then
    usage_ok=0
  fi
}

scenario_sec_cli_usage() {
  local id='SEC-CLI-USAGE'
  local text='every malformed invocation exits 2 with bounded usage and no effect'
  local usage_home="$work/usage-home"
  local misplaced_home="$work/usage-misplaced-home"
  local verbless_home="$work/usage-verbless-home"
  local verb
  if ! lab_present; then
    fail "$id" "$text"
    return
  fi
  canary_reset
  usage_ok=1
  usage_index=0
  lab_home_env="$usage_home"
  usage_case not-a-verb
  usage_case --not-an-option
  usage_case init --home "$misplaced_home"
  usage_case add
  usage_case add "$fixture" extra-argument
  usage_case doctor extra-argument
  usage_case serve extra-argument
  usage_case list extra-argument
  usage_case init extra-argument
  # A missing option value must be refused before any home is selected.
  usage_case --home
  # Wrong arity on every name-taking deferred verb.  The command matrix gives
  # these arity 1, and the usage clause requires wrong arity to be refused with
  # usage rather than dispatched to a handler that might act.
  for verb in prepare start stop inspect remove; do
    usage_case "$verb"
  done
  usage_case prepare first second
  # status takes zero or one name, so two is wrong arity.
  usage_case status first second
  # A home flag with a value but no verb is not a command; it must never be
  # treated as a default verb and must not create the home it names.
  usage_case --home "$verbless_home"
  lab_home_env=""
  if [ -e "$usage_home" ] || [ -e "$misplaced_home" ] || [ -e "$verbless_home" ]; then
    usage_ok=0
  fi
  canary_clean || usage_ok=0
  if [ "$usage_ok" -eq 1 ]; then
    pass "$id" "$text"
  else
    fail "$id" "$text"
  fi
}

# ---------------------------------------------------------------------------
# WF-HOME-INIT -- integration
# ---------------------------------------------------------------------------

scenario_wf_home_init() {
  local id='WF-HOME-INIT'
  local text='init publishes one owner-private canonical home that survives exact retry'
  local target="$work/init-home"
  local init_rc retry_rc init_identity retry_identity init_digest retry_digest
  local init_ok=1
  if ! lab_present; then
    fail "$id" "$text"
    return
  fi
  canary_reset
  lab_home_env=""
  # An inherited permissive process umask must not be mistaken for private
  # defaults, so publication runs under umask 000.
  lab_environment
  capture init-permissive "${sandbox_prefix[@]}" "${lab_env_args[@]}" \
    bash -c 'umask 000; exec "$0" --home "$1" init' "$lab" "$target"
  init_rc="$CAPTURE_RC"
  init_identity="$(path_identity "$target")"
  # "Preserves every durable byte" is a claim about bytes and modes, not about
  # timestamps: an idempotent republication may legitimately re-apply an already
  # correct mode, so the durable instrument is the faithful one here.
  init_digest="$(durable_digest_of "$target")"
  lab_run init-retry --home "$target" init
  retry_rc="$CAPTURE_RC"
  retry_identity="$(path_identity "$target")"
  retry_digest="$(durable_digest_of "$target")"
  [ "$init_rc" -eq 0 ] && [ "$retry_rc" -eq 0 ] || init_ok=0
  [ -d "$target" ] || init_ok=0
  private_boundary_ok "$target" || init_ok=0
  [ "$init_identity" != 'no-identity' ] || init_ok=0
  [ "$init_identity" = "$retry_identity" ] || init_ok=0
  [ "$init_digest" != 'absent' ] && [ "$init_digest" != 'digest-error' ] || init_ok=0
  [ "$init_digest" = "$retry_digest" ] || init_ok=0
  # A private empty tree is not a published home: the compatible closed receipt
  # named by the contract has to exist, at mode 0600, unaliased, with the only
  # G0-compatible apiVersions.
  authority_ok "$target" || init_ok=0
  canary_clean || init_ok=0
  # And the published boundary has to be a real one: the existing verified path
  # accepts it and onboards into it with the reference identity.  A facade whose
  # init leaves an unusable boundary cannot pass this even if every mode is
  # right.
  oracle_run init-accepted --home "$target" experiment install "$fixture"
  [ "$CAPTURE_RC" -eq 0 ] || init_ok=0
  [ "$(jq -r '.installationKey // empty' "$CAPTURE_OUT" 2>/dev/null)" = "$oracle_key" ] \
    || init_ok=0
  if [ "$init_ok" -eq 1 ]; then
    pass "$id" "$text"
  else
    fail "$id" "$text"
  fi
}

# ---------------------------------------------------------------------------
# WF-HOME-SELECT -- integration
# ---------------------------------------------------------------------------

scenario_wf_home_select() {
  local id='WF-HOME-SELECT'
  local text='explicit, environment, and account-database homes are ordered and never merge'
  local explicit_home="$work/select-explicit"
  local env_home="$work/select-env"
  local explicit_rc env_rc default_rc
  local explicit_identity env_identity
  local account_before account_after
  local explicit_only=0
  if ! lab_present; then
    fail "$id" "$text"
    return
  fi
  canary_reset
  # --home outranks AGENT_LAB_HOME.
  lab_home_env="$env_home"
  lab_run select-explicit --home "$explicit_home" init
  explicit_rc="$CAPTURE_RC"
  if [ -d "$explicit_home" ] && [ ! -e "$env_home" ]; then
    explicit_only=1
  fi
  # AGENT_LAB_HOME outranks the account-database default.
  lab_run select-env init
  env_rc="$CAPTURE_RC"
  # The account-database default is reported, never created by a read path.
  lab_home_env=""
  account_before="$(digest_of "$account_home")"
  lab_run select-default doctor
  default_rc="$CAPTURE_RC"
  account_after="$(digest_of "$account_home")"
  reclaim_account_probe "$account_before"
  explicit_identity="$(path_identity "$explicit_home")"
  env_identity="$(path_identity "$env_home")"
  if [ "$explicit_rc" -eq 0 ] && [ "$env_rc" -eq 0 ] && [ "$default_rc" -eq 0 ] \
     && [ "$explicit_only" -eq 1 ] \
     && [ -d "$env_home" ] \
     && authority_ok "$explicit_home" \
     && authority_ok "$env_home" \
     && [ "$explicit_identity" != 'no-identity' ] \
     && [ "$env_identity" != 'no-identity' ] \
     && [ "$explicit_identity" != "$env_identity" ] \
     && grep -Fq "$account_home" "$CAPTURE_OUT" \
     && [ "$account_before" = "$account_after" ] \
     && [ ! -e "$decoy_home/.agent-lab" ] \
     && canary_clean; then
    pass "$id" "$text"
  else
    fail "$id" "$text"
  fi
}

# ---------------------------------------------------------------------------
# SEC-HOME-UNSAFE -- integration
# ---------------------------------------------------------------------------

scenario_sec_home_unsafe() {
  local id='SEC-HOME-UNSAFE'
  local text='an unsafe selected root is refused before any effect while an adjacent private root succeeds'
  local unsafe_ok=1
  local symlink_target="$work/unsafe-symlink-target"
  local symlink_home="$work/unsafe-symlink"
  local file_home="$work/unsafe-file"
  local open_home="$work/unsafe-open"
  local child_home="$work/unsafe-child"
  local child_link_home="$work/unsafe-child-link"
  local child_alias_home="$work/unsafe-child-alias"
  local external_dir="$work/unsafe-external"
  local adjacent_home="$work/unsafe-adjacent"
  local before external_before
  if ! lab_present; then
    fail "$id" "$text"
    return
  fi
  canary_reset
  lab_home_env=""
  mkdir -p "$external_dir" || unsafe_ok=0
  chmod 0700 "$external_dir" || unsafe_ok=0

  # A symlinked selected root is refused and its target subtree is untouched.
  mkdir -p "$symlink_target" || unsafe_ok=0
  printf 'pre-existing\n' > "$symlink_target/witness" || unsafe_ok=0
  ln -s "$symlink_target" "$symlink_home" || unsafe_ok=0
  before="$(digest_of "$symlink_target")"
  lab_run unsafe-symlink --home "$symlink_home" init
  [ "$CAPTURE_RC" -eq 1 ] || unsafe_ok=0
  [ "$(digest_of "$symlink_target")" = "$before" ] || unsafe_ok=0

  # A non-directory selected root is refused without repair.
  printf 'not a home\n' > "$file_home" || unsafe_ok=0
  before="$(digest_of "$file_home")"
  lab_run unsafe-file --home "$file_home" init
  [ "$CAPTURE_RC" -eq 1 ] || unsafe_ok=0
  [ "$(digest_of "$file_home")" = "$before" ] || unsafe_ok=0

  # A group and world writable selected root is refused without chmod.
  mkdir -p "$open_home" || unsafe_ok=0
  chmod 0777 "$open_home" || unsafe_ok=0
  before="$(digest_of "$open_home")"
  lab_run unsafe-open --home "$open_home" init
  [ "$CAPTURE_RC" -eq 1 ] || unsafe_ok=0
  [ "$(digest_of "$open_home")" = "$before" ] || unsafe_ok=0

  # A group and world writable protected authority child is refused too.
  if ready_home "$child_home" unsafe-child-init; then
    chmod 0666 "$child_home/home.json" || unsafe_ok=0
    before="$(digest_of "$child_home")"
    lab_run unsafe-child --home "$child_home" init
    [ "$CAPTURE_RC" -eq 1 ] || unsafe_ok=0
    [ "$(digest_of "$child_home")" = "$before" ] || unsafe_ok=0
  else
    unsafe_ok=0
  fi

  # A symlinked protected authority child pointing at an owner-private file
  # outside the home.  A facade that opens authority without O_NOFOLLOW would
  # rewrite the external target while the lexical home tree still looks stable,
  # so the external file is digested separately.
  if ready_home "$child_link_home" unsafe-child-link-init; then
    cp "$child_link_home/home.json" "$external_dir/home.json" || unsafe_ok=0
    chmod 0600 "$external_dir/home.json" || unsafe_ok=0
    find "$child_link_home/home.json" -maxdepth 0 -delete 2>/dev/null || unsafe_ok=0
    ln -s "$external_dir/home.json" "$child_link_home/home.json" || unsafe_ok=0
    before="$(digest_of "$child_link_home")"
    external_before="$(digest_of "$external_dir")"
    lab_run unsafe-child-link --home "$child_link_home" init
    [ "$CAPTURE_RC" -eq 1 ] || unsafe_ok=0
    [ "$(digest_of "$child_link_home")" = "$before" ] || unsafe_ok=0
    [ "$(digest_of "$external_dir")" = "$external_before" ] || unsafe_ok=0
    [ -L "$child_link_home/home.json" ] || unsafe_ok=0
  else
    unsafe_ok=0
  fi

  # An unexpectedly aliased protected authority child: a second hard link to
  # config.json outside the home, so the authority no longer has one name.
  if ready_home "$child_alias_home" unsafe-child-alias-init; then
    ln "$child_alias_home/config.json" "$external_dir/config-alias.json" || unsafe_ok=0
    before="$(digest_of "$child_alias_home")"
    external_before="$(digest_of "$external_dir")"
    lab_run unsafe-child-alias --home "$child_alias_home" init
    [ "$CAPTURE_RC" -eq 1 ] || unsafe_ok=0
    [ "$(digest_of "$child_alias_home")" = "$before" ] || unsafe_ok=0
    [ "$(digest_of "$external_dir")" = "$external_before" ] || unsafe_ok=0
  else
    unsafe_ok=0
  fi

  # The refusal is targeted: an adjacent owner-private boundary still succeeds.
  lab_run unsafe-adjacent --home "$adjacent_home" init
  [ "$CAPTURE_RC" -eq 0 ] || unsafe_ok=0
  [ -d "$adjacent_home" ] || unsafe_ok=0
  authority_ok "$adjacent_home" || unsafe_ok=0

  canary_clean || unsafe_ok=0
  if [ "$unsafe_ok" -eq 1 ]; then
    pass "$id" "$text"
  else
    fail "$id" "$text"
  fi
}

# ---------------------------------------------------------------------------
# SEC-HOME-INCOMPATIBLE -- integration
# ---------------------------------------------------------------------------

scenario_sec_home_incompatible() {
  local id='SEC-HOME-INCOMPATIBLE'
  local text='a closed receipt with an unsupported apiVersion is refused without migration'
  local incompatible_ok=1
  local target="$work/incompatible-home"
  local config_target="$work/incompatible-config-home"
  local before config_before
  if ! lab_present; then
    fail "$id" "$text"
    return
  fi
  canary_reset
  lab_home_env=""
  if ! ready_home "$target" incompatible-init \
     || ! ready_home "$config_target" incompatible-config-init; then
    fail "$id" "$text"
    return
  fi
  # Re-serialize in the product's own canonical form at mode 0600 so the receipt
  # stays closed and canonically readable and apiVersion is the only failing
  # clause.  Anything else would test malformedness, not incompatibility.
  if ! python3 -I -B - "$target/home.json" 'agent-lab.home/v0alpha1' \
       'agent-lab.home/v99unsupported' <<'PY'
from __future__ import annotations

import json
import os
from pathlib import Path
import sys

path = Path(sys.argv[1])
value = json.loads(path.read_bytes())
if value.get("apiVersion") != sys.argv[2]:
    raise SystemExit(1)
value["apiVersion"] = sys.argv[3]
encoded = json.dumps(
    value, ensure_ascii=True, separators=(",", ":"), sort_keys=True
).encode("ascii") + b"\n"
descriptor = os.open(path, os.O_WRONLY | os.O_TRUNC)
try:
    os.write(descriptor, encoded)
finally:
    os.close(descriptor)
os.chmod(path, 0o600)
PY
  then
    incompatible_ok=0
  fi
  # The same treatment for the config receipt, so an implementation that only
  # version-checks one of the two compatible receipts cannot pass.  The home
  # receipt binds the config receipt by digest, so the binding is re-established
  # after the edit and the fixture stays internally consistent: otherwise this
  # would test a broken binding rather than a known unsupported version.  The
  # binding rule is not assumed -- it is confirmed against the untouched receipt
  # first, and an unconfirmable rule is uncertainty, not a product result.
  python3 -I -B - "$config_target" 'agent-lab.config/v0alpha1' \
    'agent-lab.config/v99unsupported' <<'PY'
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import sys

home = Path(sys.argv[1])
config_path = home / "config.json"
home_path = home / "home.json"


def canonical(value: dict) -> bytes:
    return json.dumps(
        value, ensure_ascii=True, separators=(",", ":"), sort_keys=True
    ).encode("ascii")


def digest_of(payload: bytes) -> str:
    return "sha256:" + hashlib.sha256(payload.rstrip(b"\n")).hexdigest()


config_bytes = config_path.read_bytes()
home_value = json.loads(home_path.read_bytes())
if digest_of(config_bytes) != home_value.get("configDigest"):
    # The observed binding rule no longer holds, so a faithful fixture cannot be
    # built here.
    raise SystemExit(2)

config_value = json.loads(config_bytes)
if config_value.get("apiVersion") != sys.argv[2]:
    raise SystemExit(1)
config_value["apiVersion"] = sys.argv[3]
config_encoded = canonical(config_value) + b"\n"
home_value["configDigest"] = digest_of(config_encoded)
home_encoded = canonical(home_value) + b"\n"

for path, encoded in ((config_path, config_encoded), (home_path, home_encoded)):
    descriptor = os.open(path, os.O_WRONLY | os.O_TRUNC)
    try:
        os.write(descriptor, encoded)
    finally:
        os.close(descriptor)
    os.chmod(path, 0o600)
PY
  case "$?" in
    0) ;;
    2) infra_stop 'the closed home receipt binding rule could not be confirmed' ;;
    *) incompatible_ok=0 ;;
  esac
  before="$(digest_of "$target")"
  config_before="$(digest_of "$config_target")"
  # A read-modifying verb and an effectful verb must both refuse.
  lab_run incompatible-init-refusal --home "$target" init
  [ "$CAPTURE_RC" -eq 1 ] || incompatible_ok=0
  grep -Fqi 'version' "$CAPTURE_ERR" || incompatible_ok=0
  bounded_output "$CAPTURE_ERR" 2048 20 || incompatible_ok=0
  lab_run incompatible-add --home "$target" add "$fixture"
  [ "$CAPTURE_RC" -eq 1 ] || incompatible_ok=0
  lab_run incompatible-config-add --home "$config_target" add "$fixture"
  [ "$CAPTURE_RC" -eq 1 ] || incompatible_ok=0
  grep -Fqi 'version' "$CAPTURE_ERR" || incompatible_ok=0
  # No migration, rewrite, repair, acquisition, or Docker effect.
  [ "$(digest_of "$target")" = "$before" ] || incompatible_ok=0
  [ "$(digest_of "$config_target")" = "$config_before" ] || incompatible_ok=0
  [ "$before" != 'absent' ] || incompatible_ok=0
  canary_clean || incompatible_ok=0
  if [ "$incompatible_ok" -eq 1 ]; then
    pass "$id" "$text"
  else
    fail "$id" "$text"
  fi
}

# ---------------------------------------------------------------------------
# REC-HOME-UNCERTAIN -- integration
# ---------------------------------------------------------------------------

scenario_rec_home_uncertain() {
  local id='REC-HOME-UNCERTAIN'
  local text='an unprovable selected boundary exits 125 and is preserved unchanged'
  local uncertain_ok=1
  local target="$work/uncertain-home"
  local bound_lock="$work/uncertain-saved.lock"
  local before after
  if ! lab_present; then
    fail "$id" "$text"
    return
  fi
  canary_reset
  lab_home_env=""
  if ! ready_home "$target" uncertain-init; then
    fail "$id" "$text"
    return
  fi
  # Deterministic fault injection on a bound authority, not timing: the receipt
  # still binds a device and inode that no longer identify a readable regular
  # file, so identity can be neither proved nor disproved.
  if [ -f "$target/state/locks/experiments.lock" ]; then
    mv "$target/state/locks/experiments.lock" "$bound_lock" || uncertain_ok=0
    mkfifo -m 600 "$target/state/locks/experiments.lock" || uncertain_ok=0
  else
    uncertain_ok=0
  fi
  before="$(digest_of "$target")"
  lab_run uncertain-add --home "$target" add "$fixture"
  after="$(digest_of "$target")"
  # 125 exactly: an unprovable boundary is never a known denial or a success.
  [ "$CAPTURE_RC" -eq 125 ] || uncertain_ok=0
  [ "$before" = "$after" ] || uncertain_ok=0
  [ "$before" != 'absent' ] || uncertain_ok=0
  canary_clean || uncertain_ok=0
  find "$target/state/locks/experiments.lock" -type p -delete 2>/dev/null || true
  if [ "$uncertain_ok" -eq 1 ]; then
    pass "$id" "$text"
  else
    fail "$id" "$text"
  fi
}

# ---------------------------------------------------------------------------
# WF-ADD-INSTALL -- e2e.  add_home, add_key, and add_receipt are shared with
# WF-ADD-RETRY and SEC-ADD-COLLISION, which continue the same boundary.
# ---------------------------------------------------------------------------

add_home=""
add_key=""
add_receipt=""

scenario_wf_add_install() {
  local id='WF-ADD-INSTALL'
  local text='add reaches the existing verified install path and reports its stable identity'
  local add_ok=1
  local add_name envelope_count
  add_home="$work/add-home"
  if ! lab_present; then
    fail "$id" "$text"
    return
  fi
  canary_reset
  lab_home_env=""
  if ! ready_home "$add_home" add-init; then
    fail "$id" "$text"
    return
  fi
  paths_of "$add_home" "$work/add-before.paths"
  lab_run add-install --home "$add_home" add "$fixture"
  paths_of "$add_home" "$work/add-after.paths"
  [ "$CAPTURE_RC" -eq 0 ] || add_ok=0
  add_name="$(jq -r '.name // empty' "$CAPTURE_OUT" 2>/dev/null)"
  add_key="$(jq -r '.installationKey // empty' "$CAPTURE_OUT" 2>/dev/null)"
  add_receipt="$(jq -r '.receiptDigest // empty' "$CAPTURE_OUT" 2>/dev/null)"
  # Equivalence with the independently produced reference identity.  A partial
  # facade stub that fabricates success cannot reproduce these values.
  [ -n "$add_key" ] && [ "$add_key" = "$oracle_key" ] || add_ok=0
  [ -n "$add_receipt" ] && [ "$add_receipt" = "$oracle_receipt" ] || add_ok=0
  [ "$add_name" = "$oracle_name" ] || add_ok=0
  # Exactly one closed evidence envelope beside the staging boundary.
  envelope_count="$(find "$add_home/experiments" -mindepth 1 -maxdepth 1 -type d \
    ! -name '.staging' 2>/dev/null | wc -l)"
  [ "$envelope_count" -eq 1 ] || add_ok=0
  [ -d "$add_home/experiments/$oracle_name" ] || add_ok=0
  # And the durable effect is *only* the install: the boundary delta equals the
  # delta the existing verified path itself produces for the same fixture, so a
  # facade that also prepares, activates, or records extra runtime state under
  # the home cannot pass even though its reported identity is right.
  LC_ALL=C comm -13 "$work/add-before.paths" "$work/add-after.paths" \
    > "$work/add-added.paths"
  LC_ALL=C comm -23 "$work/add-before.paths" "$work/add-after.paths" \
    > "$work/add-removed.paths"
  cmp -s "$work/add-added.paths" "$work/reference-added.paths" || add_ok=0
  [ ! -s "$work/add-removed.paths" ] || add_ok=0
  # No prepare, activation, acquisition, Broker, or Docker effect.
  canary_clean || add_ok=0
  if [ "$add_ok" -eq 1 ]; then
    pass "$id" "$text"
  else
    fail "$id" "$text"
  fi
}

# ---------------------------------------------------------------------------
# WF-ADD-RETRY -- integration
# ---------------------------------------------------------------------------

scenario_wf_add_retry() {
  local id='WF-ADD-RETRY'
  local text='an exact repeated add is unchanged and byte-identical'
  local retry_ok=1
  local before after
  if ! lab_present; then
    fail "$id" "$text"
    return
  fi
  canary_reset
  lab_home_env=""
  if [ -z "$add_home" ] || [ ! -d "$add_home" ] || [ -z "$add_key" ]; then
    fail "$id" "$text"
    return
  fi
  before="$(digest_of "$add_home")"
  lab_run add-retry --home "$add_home" add "$fixture"
  after="$(digest_of "$add_home")"
  [ "$CAPTURE_RC" -eq 0 ] || retry_ok=0
  jq -e --arg key "$add_key" --arg receipt "$add_receipt" \
    '.changed == false and .installationKey == $key and .receiptDigest == $receipt' \
    "$CAPTURE_OUT" >/dev/null 2>&1 || retry_ok=0
  # No durable byte, mode, or inode rewritten anywhere in the boundary.
  [ "$before" = "$after" ] || retry_ok=0
  [ "$before" != 'absent' ] || retry_ok=0
  canary_clean || retry_ok=0
  if [ "$retry_ok" -eq 1 ]; then
    pass "$id" "$text"
  else
    fail "$id" "$text"
  fi
}

# ---------------------------------------------------------------------------
# SEC-ADD-COLLISION -- integration
# ---------------------------------------------------------------------------

scenario_sec_add_collision() {
  local id='SEC-ADD-COLLISION'
  local text='a colliding name with a different identity never overwrites the original'
  local collision_ok=1
  local before after
  if ! lab_present; then
    fail "$id" "$text"
    return
  fi
  canary_reset
  lab_home_env=""
  if [ -z "$add_home" ] || [ ! -d "$add_home" ] || [ -z "$add_key" ]; then
    fail "$id" "$text"
    return
  fi
  before="$(digest_of "$add_home")"
  lab_run add-collision --home "$add_home" add "$conflict_source"
  after="$(digest_of "$add_home")"
  [ "$CAPTURE_RC" -eq 1 ] || collision_ok=0
  [ "$before" = "$after" ] || collision_ok=0
  [ "$before" != 'absent' ] || collision_ok=0
  canary_clean || collision_ok=0
  if [ "$collision_ok" -eq 1 ]; then
    pass "$id" "$text"
  else
    fail "$id" "$text"
  fi
}

# ---------------------------------------------------------------------------
# REC-ADD-INTERRUPTED -- integration
# ---------------------------------------------------------------------------

scenario_rec_add_interrupted() {
  local id='REC-ADD-INTERRUPTED'
  local text='unknown publication residue exits 125 and is preserved rather than published around'
  local residue_ok=1
  local target="$work/residue-home"
  local residue_dir before after envelope_count
  if ! lab_present; then
    fail "$id" "$text"
    return
  fi
  canary_reset
  lab_home_env=""
  if ! ready_home "$target" residue-init; then
    fail "$id" "$text"
    return
  fi
  # Unrecognized, over-bound publication residue in the staging boundary: not a
  # recognized interrupted intent and not a completed result.
  residue_dir="$target/experiments/.staging/unknown-residue"
  mkdir -p "$residue_dir" || residue_ok=0
  printf 'unrecognized publication residue\n' > "$residue_dir/intent.json" || residue_ok=0
  before="$(digest_of "$target")"
  lab_run residue-add --home "$target" add "$fixture"
  after="$(digest_of "$target")"
  [ "$CAPTURE_RC" -eq 125 ] || residue_ok=0
  [ "$before" = "$after" ] || residue_ok=0
  [ "$before" != 'absent' ] || residue_ok=0
  # Reconciliation never silently discarded what it could not recognize.
  [ -f "$residue_dir/intent.json" ] || residue_ok=0

  # The positive control the contract also requires: a *recognized* interrupted
  # publication intent, produced by interrupting the existing verified path at a
  # barrier on its own staging boundary, must be reconciled by an exact retry
  # rather than refused.  Without this, always answering 125 to any residue
  # would satisfy the scenario while breaking recovery.
  before="$(digest_of "$interrupted_home")"
  lab_run interrupted-reconcile --home "$interrupted_home" add "$fixture"
  [ "$CAPTURE_RC" -eq 0 ] || residue_ok=0
  [ "$(jq -r '.installationKey // empty' "$CAPTURE_OUT" 2>/dev/null)" = "$oracle_key" ] \
    || residue_ok=0
  [ "$(jq -r '.receiptDigest // empty' "$CAPTURE_OUT" 2>/dev/null)" = "$oracle_receipt" ] \
    || residue_ok=0
  envelope_count="$(find "$interrupted_home/experiments" -mindepth 1 -maxdepth 1 -type d \
    ! -name '.staging' 2>/dev/null | wc -l)"
  [ "$envelope_count" -eq 1 ] || residue_ok=0
  # The recognized intent was reconciled, not left beside a published envelope.
  [ ! -e "$interrupted_home/experiments/.staging/experiment-install" ] || residue_ok=0
  [ "$before" != 'absent' ] || residue_ok=0
  canary_clean || residue_ok=0
  if [ "$residue_ok" -eq 1 ]; then
    pass "$id" "$text"
  else
    fail "$id" "$text"
  fi
}

# ---------------------------------------------------------------------------
# SEC-NAME-ABSENT -- e2e
# ---------------------------------------------------------------------------

scenario_sec_name_absent() {
  local id='SEC-NAME-ABSENT'
  local text='an unowned name is refused with list or add guidance and no effect'
  local name_ok=1
  local target="$work/absent-name-home"
  local before verb
  if ! lab_present; then
    fail "$id" "$text"
    return
  fi
  canary_reset
  lab_home_env=""
  if ! ready_home "$target" absent-name-init; then
    fail "$id" "$text"
    return
  fi
  before="$(digest_of "$target")"
  for verb in prepare start status stop inspect remove; do
    lab_run "absent-name-$verb" --home "$target" "$verb" ghost-experiment
    [ "$CAPTURE_RC" -eq 1 ] || name_ok=0
    # Actionable guidance names the verb that would resolve the situation.
    grep -Eqi '(^|[^a-z])(list|add)([^a-z]|$)' "$CAPTURE_ERR" || name_ok=0
    bounded_output "$CAPTURE_ERR" 2048 20 || name_ok=0
  done
  [ "$(digest_of "$target")" = "$before" ] || name_ok=0
  [ "$before" != 'absent' ] || name_ok=0
  canary_clean || name_ok=0
  if [ "$name_ok" -eq 1 ]; then
    pass "$id" "$text"
  else
    fail "$id" "$text"
  fi
}

# ---------------------------------------------------------------------------
# WF-READ-NONMUTATING -- e2e
# ---------------------------------------------------------------------------

read_ok=1
read_index=0

repeat_identical() {
  local label="read-$read_index"
  local first_rc first_out first_err
  read_index=$((read_index + 1))
  first_out="$work/$label-first.out"
  first_err="$work/$label-first.err"
  lab_run "$label-a" "$@"
  first_rc="$CAPTURE_RC"
  cp -- "$CAPTURE_OUT" "$first_out" || read_ok=0
  cp -- "$CAPTURE_ERR" "$first_err" || read_ok=0
  lab_run "$label-b" "$@"
  if [ "$CAPTURE_RC" -ne "$first_rc" ] \
     || ! cmp -s "$first_out" "$CAPTURE_OUT" \
     || ! cmp -s "$first_err" "$CAPTURE_ERR"; then
    read_ok=0
  fi
}

repeat_denial() {
  # A deferred verb whose grammar is valid is a known denial, not a usage error
  # and never a success: it must fail before effects with bounded guidance, and
  # it must do so identically every time.
  local expected="$1"
  shift
  repeat_identical "$@"
  [ "$CAPTURE_RC" -eq "$expected" ] || read_ok=0
  [ -s "$CAPTURE_ERR" ] || read_ok=0
  bounded_output "$CAPTURE_ERR" 2048 20 || read_ok=0
}

scenario_wf_read_nonmutating() {
  local id='WF-READ-NONMUTATING'
  local text='every G0 read path repeats identically and mutates nothing'
  local target="$work/read-home"
  local absent_target="$work/read-absent-home"
  local before
  if ! lab_present; then
    fail "$id" "$text"
    return
  fi
  canary_reset
  read_ok=1
  read_index=0
  lab_home_env=""
  if ! ready_home "$target" read-init; then
    fail "$id" "$text"
    return
  fi
  before="$(digest_of "$target")"
  repeat_identical --home "$target" doctor
  repeat_identical --home "$target" not-a-verb
  repeat_identical --home "$target" status ghost-experiment
  # The deferred verbs whose grammar is complete: recognized, denied as a later
  # group, and never quietly successful or effectful.
  repeat_denial 1 --home "$target" serve
  repeat_denial 1 --home "$target" list
  repeat_denial 1 --home "$target" status
  # The no-argument help path, selected through the environment.
  lab_home_env="$target"
  repeat_identical
  lab_home_env=""
  # An absent boundary is the only place a read path can be caught initializing
  # or repairing what it was only asked to observe.
  repeat_identical --home "$absent_target" doctor
  [ ! -e "$absent_target" ] || read_ok=0
  [ "$(digest_of "$target")" = "$before" ] || read_ok=0
  [ "$before" != 'absent' ] || read_ok=0
  canary_clean || read_ok=0
  if [ "$read_ok" -eq 1 ]; then
    pass "$id" "$text"
  else
    fail "$id" "$text"
  fi
}

# ---------------------------------------------------------------------------
# SEC-OUTPUT-SECRETS -- e2e
# ---------------------------------------------------------------------------

secret_seen=0

scan_secret() {
  if grep -Fq "$canary_secret" "$CAPTURE_OUT" 2>/dev/null \
     || grep -Fq "$canary_secret" "$CAPTURE_ERR" 2>/dev/null; then
    secret_seen=1
  fi
}

scenario_sec_output_secrets() {
  local id='SEC-OUTPUT-SECRETS'
  local text='no synthetic secret canary reaches output while stable identifiers stay visible'
  local secret_ok=1
  local target="$work/secret-home"
  local receipt_target="$work/secret-receipt-home"
  local secret_path
  if ! lab_present; then
    fail "$id" "$text"
    return
  fi
  canary_reset
  secret_seen=0
  lab_home_env=""
  if ! ready_home "$target" secret-init; then
    fail "$id" "$text"
    return
  fi

  # Carrier one: the environment.
  lab_run secret-doctor --home "$target" doctor
  scan_secret

  # Carrier two: an unresolvable supplied path.
  secret_path="$work/source-$canary_secret/missing"
  lab_run secret-path --home "$target" add "$secret_path"
  [ "$CAPTURE_RC" -ne 0 ] || secret_ok=0
  scan_secret

  # Carrier three: durable home metadata that forces a trusted read fault.
  if ready_home "$receipt_target" secret-receipt-init; then
    printf '{"apiVersion":"agent-lab.home/v0alpha1","canary":"%s"\n' "$canary_secret" \
      > "$receipt_target/home.json" || secret_ok=0
    chmod 0600 "$receipt_target/home.json" || secret_ok=0
    lab_run secret-receipt --home "$receipt_target" add "$fixture"
    if [ "$CAPTURE_RC" -ne 1 ] && [ "$CAPTURE_RC" -ne 125 ]; then
      secret_ok=0
    fi
    scan_secret
  else
    secret_ok=0
  fi

  # Blanket suppression must not pass: the successful path still shows the
  # stable installation identity.
  lab_run secret-add --home "$target" add "$fixture"
  [ "$CAPTURE_RC" -eq 0 ] || secret_ok=0
  grep -Fq "$oracle_key" "$CAPTURE_OUT" || secret_ok=0
  scan_secret

  [ "$secret_seen" -eq 0 ] || secret_ok=0
  canary_clean || secret_ok=0
  if [ "$secret_ok" -eq 1 ]; then
    pass "$id" "$text"
  else
    fail "$id" "$text"
  fi
}

# ---------------------------------------------------------------------------
# Frozen emission order
# ---------------------------------------------------------------------------

scenario_wf_cli_help
scenario_sec_cli_usage
scenario_wf_home_init
scenario_wf_home_select
scenario_sec_home_unsafe
scenario_sec_home_incompatible
scenario_rec_home_uncertain
scenario_wf_add_install
scenario_wf_add_retry
scenario_sec_add_collision
scenario_rec_add_interrupted
scenario_sec_name_absent
scenario_wf_read_nonmutating
scenario_sec_output_secrets

# An assertion ledger that drifted from the frozen identities cannot certify
# anything, so it is uncertainty rather than a product result.
expected_file="$work/expected-ids"
printf '%s\n' "${expected_ids[@]}" > "$expected_file"
if [ "${#expected_ids[@]}" -ne "$expected_count" ] || ! cmp -s "$expected_file" "$observed"; then
  printf 'INFRA g0 operator-surface assertion identities drifted from the frozen set\n' >&2
  infrastructure=1
fi

finish
