#!/usr/bin/env bash
set -u -o pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
agent_lab="$repo_root/scripts/agent-lab"
bounded_helper="$repo_root/tests/helpers/run-bounded.py"
fixture="$repo_root/tests/experiment/fixtures/directories/minimal"
runtime_manifest="$repo_root/packaging/agent-lab-local.manifest"
expected_count=13
work=""
failures=0
infrastructure=0

cleanup_work() {
  local failed=0
  if [ -n "$work" ] && [ -e "$work" ]; then
    find "$work" -type f -exec chmod u+rw {} + 2>/dev/null || failed=1
    find "$work" -depth -type d -exec chmod u+rwx {} + 2>/dev/null || failed=1
    find "$work" -type f -delete 2>/dev/null || failed=1
    find "$work" -type l -delete 2>/dev/null || failed=1
    find "$work" -depth -type d -exec rmdir {} + 2>/dev/null || failed=1
    [ ! -e "$work" ] || failed=1
  fi
  return "$failed"
}

finish() {
  local assertions=0
  if [ -n "${observed:-}" ] && [ -f "$observed" ]; then
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
  printf 'EXPERIMENT INSTALL STORE PASS\n'
}

if ! work="$(mktemp -d)"; then
  printf 'SUMMARY assertions=0 expected=%s failures=0 infra=1\n' "$expected_count"
  exit 125
fi
trap 'cleanup_work >/dev/null 2>&1 || true' EXIT
observed="$work/observed"
: > "$observed"

if [ ! -x "$agent_lab" ] || [ ! -f "$bounded_helper" ] || [ ! -d "$fixture" ] \
   || [ ! -f "$runtime_manifest" ] || ! command -v jq >/dev/null 2>&1 \
   || ! command -v python3 >/dev/null 2>&1 \
   || [ ! -d "$repo_root/.cache/dev/tools/cue" ] \
   || [ ! -d "$repo_root/.cache/dev/tools/cedar" ]; then
  printf 'INFRA install-store prerequisites are unavailable\n' >&2
  infrastructure=1
  finish
fi
if ! python3 -I -B "$bounded_helper" --self-test > "$work/bounded-self-test.out" 2> "$work/bounded-self-test.err"; then
  printf 'INFRA bounded command helper self-test failed\n' >&2
  infrastructure=1
  finish
fi

export AGENT_LAB_CUE_TOOL_DIR="$repo_root/.cache/dev/tools/cue"
export AGENT_LAB_CEDAR_TOOL_DIR="$repo_root/.cache/dev/tools/cedar"

pass() { printf 'PASS %s %s\n' "$1" "$2"; printf '%s\n' "$1" >> "$observed"; }
fail() { printf 'FAIL %s %s\n' "$1" "$2"; printf '%s\n' "$1" >> "$observed"; failures=$((failures + 1)); }

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
    --timeout 5 --status "$status" --stdout "$CAPTURE_OUT" --stderr "$CAPTURE_ERR" -- "$@" || CAPTURE_RC=$?
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

init_home() {
  local home="$1"
  capture "init-$(basename -- "$home")" "$agent_lab" --home "$home" init
  if [ "$CAPTURE_RC" -ne 0 ]; then
    printf 'INFRA temporary Agent Lab home initialization failed: %s\n' \
      "$(tr '\n' ' ' < "$CAPTURE_ERR")" >&2
    infrastructure=1
    finish
  fi
}

state_receipt() {
  python3 -I -B - "$1" <<'PY'
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import stat
import sys

root = Path(sys.argv[1])
if not os.path.lexists(root):
    print("absent")
    raise SystemExit(0)

records: list[list[object]] = []

def visit(path: Path, relative: str) -> None:
    metadata = path.lstat()
    kind = "other"
    content = ""
    if stat.S_ISDIR(metadata.st_mode):
        kind = "directory"
    elif stat.S_ISREG(metadata.st_mode):
        kind = "file"
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        try:
            chunks: list[bytes] = []
            remaining = metadata.st_size + 1
            while remaining:
                chunk = os.read(descriptor, min(65_536, remaining))
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
            content = hashlib.sha256(b"".join(chunks)).hexdigest()
        finally:
            os.close(descriptor)
    elif stat.S_ISLNK(metadata.st_mode):
        kind = "symlink"
        content = os.readlink(path)
    records.append([
        relative,
        kind,
        stat.S_IMODE(metadata.st_mode),
        metadata.st_uid,
        metadata.st_gid,
        metadata.st_nlink,
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
        content,
    ])
    if kind == "directory" and relative != "cache":
        for child in sorted(path.iterdir(), key=lambda item: os.fsencode(item.name)):
            child_relative = child.name if relative == "." else f"{relative}/{child.name}"
            visit(child, child_relative)

visit(root, ".")
encoded = json.dumps(records, ensure_ascii=True, separators=(",", ":")).encode("ascii")
print("sha256:" + hashlib.sha256(encoded).hexdigest())
PY
}

verify_install_envelope() {
  python3 -I -B - "$1" "$2" "$3" "$4" "$5" "$6" <<'PY'
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import stat
import sys

home = Path(sys.argv[1])
name = sys.argv[2]
source = Path(sys.argv[3])
checked_path = Path(sys.argv[4])
decision_path = Path(sys.argv[5])
result_path = Path(sys.argv[6])
target = home / "experiments" / name

def canonical(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=True, separators=(",", ":"), sort_keys=True).encode("ascii")

def digest(data: bytes) -> str:
    return "sha256:" + hashlib.sha256(data).hexdigest()

def identity_digest(domain: bytes, value: object) -> str:
    return digest(domain + canonical(value))

def strings(value: object) -> set[str]:
    found: set[str] = set()
    if isinstance(value, str):
        found.add(value)
    elif isinstance(value, dict):
        for key, item in value.items():
            found.add(key)
            found.update(strings(item))
    elif isinstance(value, list):
        for item in value:
            found.update(strings(item))
    return found

expected_paths = {
    "artifact",
    "artifact/experiment.cue",
    "records",
    "records/decision.json",
    "records/install.json",
    "records/plan.json",
    "records/provenance.json",
}
actual_paths = {
    str(path.relative_to(target))
    for path in target.rglob("*")
}
assert actual_paths == expected_paths
for relative in (".", "artifact", "records"):
    path = target if relative == "." else target / relative
    metadata = path.lstat()
    assert stat.S_ISDIR(metadata.st_mode)
    assert stat.S_IMODE(metadata.st_mode) == 0o500
    assert metadata.st_uid == os.getuid()
for relative in expected_paths - {"artifact", "records"}:
    metadata = (target / relative).lstat()
    assert stat.S_ISREG(metadata.st_mode)
    assert stat.S_IMODE(metadata.st_mode) == 0o400
    assert metadata.st_uid == os.getuid() and metadata.st_nlink == 1

artifact_bytes = (target / "artifact/experiment.cue").read_bytes()
assert artifact_bytes == (source / "experiment.cue").read_bytes()
checked = json.loads(checked_path.read_bytes())
expected_plan_bytes = canonical(checked["plan"]) + b"\n"
plan_bytes = (target / "records/plan.json").read_bytes()
decision_bytes = (target / "records/decision.json").read_bytes()
provenance_bytes = (target / "records/provenance.json").read_bytes()
receipt_bytes = (target / "records/install.json").read_bytes()
assert plan_bytes == expected_plan_bytes
assert decision_bytes == decision_path.read_bytes()

plan = json.loads(plan_bytes)
decision = json.loads(decision_bytes)
provenance = json.loads(provenance_bytes)
receipt = json.loads(receipt_bytes)
for raw, value in ((plan_bytes, plan), (decision_bytes, decision), (provenance_bytes, provenance), (receipt_bytes, receipt)):
    assert raw == canonical(value) + b"\n"
assert decision["verdict"] == "permit"
plan_digest = identity_digest(b"agent-lab.experiment-plan.v1\0", plan)
assert decision["binding"]["planDigest"] == plan_digest
assert isinstance(provenance, dict) and isinstance(provenance.get("apiVersion"), str)
assert not any(item.startswith("/") for item in strings(provenance))

selected_entries: list[dict[str, object]] = []
for member in plan["spec"]["members"]:
    resolved = member["resolvedImage"]
    if resolved["origin"] == "direct":
        continue
    selected_entries.append({
        "entryDigest": resolved["entryDigest"],
        "generation": resolved["generation"],
        "name": member["requestedSelector"]["catalogName"],
        "origin": resolved["origin"],
        "subject": resolved["subject"],
    })
selected_entries.sort(key=lambda item: (str(item["origin"]).encode(), str(item["name"]).encode()))

identity = {
    "authorizationDigest": decision["binding"]["authorizationDigest"],
    "contractDigest": plan["contract"]["digest"],
    "planDigest": decision["binding"]["planDigest"],
    "selectedEntries": selected_entries,
    "sourceDigest": decision["binding"]["sourceDigest"],
}
assert identity["sourceDigest"] == checked["source"]["digest"]
assert provenance["authorizationDigest"] == identity["authorizationDigest"]
assert provenance["contractDigest"] == identity["contractDigest"]
assert provenance["planDigest"] == identity["planDigest"]
assert provenance["selectedEntries"] == identity["selectedEntries"]
assert provenance["source"]["digest"] == identity["sourceDigest"]

decision_digest = identity_digest(b"agent-lab.experiment-decision.v1\0", decision)
provenance_digest = identity_digest(b"agent-lab.experiment-provenance.v1\0", provenance)
records = {
    "artifact/experiment.cue": {
        "digest": digest(artifact_bytes),
        "schema": "agent-lab/v0alpha1",
    },
    "records/decision.json": {
        "digest": decision_digest,
        "schema": decision["apiVersion"],
    },
    "records/plan.json": {
        "digest": plan_digest,
        "schema": plan["apiVersion"],
    },
    "records/provenance.json": {
        "digest": provenance_digest,
        "schema": provenance["apiVersion"],
    },
}
installation_key = identity_digest(b"agent-lab.experiment-installation-key.v1\0", identity)
assert receipt == {
    "apiVersion": "agent-lab.experiment-install/v0alpha1",
    "identity": identity,
    "installationKey": installation_key,
    "kind": "ExperimentInstallationReceipt",
    "name": name,
    "records": records,
}
receipt_digest = identity_digest(b"agent-lab.experiment-install-receipt.v1\0", receipt)
assert len({plan_digest, decision_digest, provenance_digest, receipt_digest}) == 4

result_bytes = result_path.read_bytes()
result = json.loads(result_bytes)
assert result_bytes == canonical(result) + b"\n"
assert result.get("changed") is True
assert result.get("name") == name
assert result.get("installationKey") == installation_key
assert result.get("receiptDigest") == receipt_digest
PY
}

missing_home="$work/missing-home"
missing_before="$(state_receipt "$missing_home")" || infrastructure=1
capture missing-install "$agent_lab" --home "$missing_home" experiment install "$fixture"
missing_after="$(state_receipt "$missing_home")" || infrastructure=1
if [ "$CAPTURE_RC" -eq 1 ] && [ ! -s "$CAPTURE_OUT" ] \
   && [ "$missing_before" = absent ] && [ "$missing_after" = absent ]; then
  pass INST-HOME-001 "install requires an initialized home without creating one"
else
  fail INST-HOME-001 "install requires an initialized home without creating one"
fi

core_home="$work/core-home"
init_home "$core_home"
unknown_before="$(state_receipt "$core_home")" || infrastructure=1
capture unknown-inspect "$agent_lab" --home "$core_home" experiment inspect missing-experiment
unknown_after="$(state_receipt "$core_home")" || infrastructure=1
if [ "$CAPTURE_RC" -eq 1 ] && [ ! -s "$CAPTURE_OUT" ] \
   && [ "$unknown_before" = "$unknown_after" ]; then
  pass INST-UNKNOWN-001 "inspect reports an unknown name without mutating the initialized home"
else
  fail INST-UNKNOWN-001 "inspect reports an unknown name without mutating the initialized home"
fi

name_home="$work/name-home"
init_home "$name_home"
name_source="$work/name-source"
name_63="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
mkdir "$name_source"
sed "s/first-experiment/$name_63/" "$fixture/experiment.cue" > "$name_source/experiment.cue"
capture name-check "$agent_lab" --home "$name_home" experiment check "$name_source"
name_check_rc="$CAPTURE_RC"
name_check_out="$CAPTURE_OUT"
name_check_err="$CAPTURE_ERR"
capture name-decision "$agent_lab" --home "$name_home" experiment authorize install "$name_source"
name_decision_rc="$CAPTURE_RC"
name_decision_out="$CAPTURE_OUT"
name_decision_err="$CAPTURE_ERR"
capture name-install "$agent_lab" --home "$name_home" experiment install "$name_source"
name_install_rc="$CAPTURE_RC"
name_install_out="$CAPTURE_OUT"
name_install_err="$CAPTURE_ERR"
capture name-inspect "$agent_lab" --home "$name_home" experiment inspect "$name_63"
name_inspect_rc="$CAPTURE_RC"
name_inspect_out="$CAPTURE_OUT"
name_inspect_err="$CAPTURE_ERR"
if [ "${#name_63}" -eq 63 ] \
   && [ "$name_check_rc" -eq 0 ] && [ ! -s "$name_check_err" ] \
   && jq -e --arg name "$name_63" '.plan.metadata.requestedName == $name' "$name_check_out" >/dev/null 2>&1 \
   && [ "$name_decision_rc" -eq 0 ] && [ ! -s "$name_decision_err" ] \
   && jq -e --arg name "$name_63" '.verdict == "permit" and .resource.requestedName == $name' "$name_decision_out" >/dev/null 2>&1 \
   && [ "$name_install_rc" -eq 0 ] && [ ! -s "$name_install_err" ] \
   && jq -e --arg name "$name_63" '.changed == true and .name == $name' "$name_install_out" >/dev/null 2>&1 \
   && [ "$name_inspect_rc" -eq 0 ] && [ ! -s "$name_inspect_err" ] \
   && jq -e --arg name "$name_63" '.state == "installed" and .name == $name' "$name_inspect_out" >/dev/null 2>&1; then
  pass INST-NAME-001 "the maximum-length valid Experiment name checks, authorizes, installs, and inspects"
else
  fail INST-NAME-001 "the maximum-length valid Experiment name checks, authorizes, installs, and inspects"
fi

capture core-check "$agent_lab" --home "$core_home" experiment check "$fixture"
check_out="$CAPTURE_OUT"
check_rc="$CAPTURE_RC"
capture core-decision "$agent_lab" --home "$core_home" experiment authorize install "$fixture"
decision_out="$CAPTURE_OUT"
decision_rc="$CAPTURE_RC"
if [ "$check_rc" -ne 0 ] || [ "$decision_rc" -ne 0 ]; then
  printf 'INFRA prerequisite check/authorization failed for the canonical fixture\n' >&2
  infrastructure=1
  finish
fi
capture core-install "$agent_lab" --home "$core_home" experiment install "$fixture"
core_result="$CAPTURE_OUT"
core_install_rc="$CAPTURE_RC"
if [ "$core_install_rc" -eq 0 ] && [ ! -s "$CAPTURE_ERR" ] \
   && jq -e '.changed == true and .name == "first-experiment" and (.installationKey | startswith("sha256:")) and (.receiptDigest | startswith("sha256:"))' \
     "$core_result" >/dev/null 2>&1; then
  pass INST-PERMIT-001 "a fresh permit publishes one named installation and canonical identity result"
else
  fail INST-PERMIT-001 "a fresh permit publishes one named installation and canonical identity result"
fi

verify_install_envelope \
  "$core_home" first-experiment "$fixture" "$check_out" "$decision_out" "$core_result" \
  > "$work/verify-envelope.out" 2> "$work/verify-envelope.err"
verify_rc=$?
if [ "$verify_rc" -eq 0 ]; then
  pass INST-RECEIPT-001 "stored exact bytes, modes, schemas, and independent hashes are receipt-bound"
else
  fail INST-RECEIPT-001 "stored exact bytes, modes, schemas, and independent hashes are receipt-bound"
fi

core_before_inspect="$(state_receipt "$core_home")" || infrastructure=1
capture core-inspect "$agent_lab" --home "$core_home" experiment inspect first-experiment
core_inspect_rc="$CAPTURE_RC"
core_after_inspect="$(state_receipt "$core_home")" || infrastructure=1
core_key="$(jq -r '.installationKey // empty' "$core_result" 2>/dev/null)"
core_receipt="$(jq -r '.receiptDigest // empty' "$core_result" 2>/dev/null)"
if [ "$core_inspect_rc" -eq 0 ] && [ ! -s "$CAPTURE_ERR" ] \
   && jq -e --arg key "$core_key" --arg receipt "$core_receipt" \
     '.name == "first-experiment" and .state == "installed" and .installationKey == $key and .receiptDigest == $receipt' \
     "$CAPTURE_OUT" >/dev/null 2>&1 \
   && [ "$core_before_inspect" = "$core_after_inspect" ]; then
  pass INST-INSPECT-001 "inspect read-only verifies and reports the exact installed identity"
else
  fail INST-INSPECT-001 "inspect read-only verifies and reports the exact installed identity"
fi

core_before_retry="$(state_receipt "$core_home")" || infrastructure=1
capture core-retry "$agent_lab" --home "$core_home" experiment install "$fixture"
core_after_retry="$(state_receipt "$core_home")" || infrastructure=1
if [ "$CAPTURE_RC" -eq 0 ] && [ ! -s "$CAPTURE_ERR" ] \
   && jq -e --arg key "$core_key" --arg receipt "$core_receipt" \
     '.changed == false and .name == "first-experiment" and .installationKey == $key and .receiptDigest == $receipt' \
     "$CAPTURE_OUT" >/dev/null 2>&1 \
   && [ "$core_before_retry" = "$core_after_retry" ]; then
  pass INST-RETRY-001 "exact retry returns changed false without rewriting the verified envelope"
else
  fail INST-RETRY-001 "exact retry returns changed false without rewriting the verified envelope"
fi

conflict_source="$work/conflict-source"
mkdir "$conflict_source"
sed 's/sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/' \
  "$fixture/experiment.cue" > "$conflict_source/experiment.cue"
core_before_conflict="$(state_receipt "$core_home")" || infrastructure=1
capture core-conflict "$agent_lab" --home "$core_home" experiment install "$conflict_source"
core_after_conflict="$(state_receipt "$core_home")" || infrastructure=1
if [ "$CAPTURE_RC" -eq 1 ] && [ ! -s "$CAPTURE_OUT" ] \
   && [ "$core_before_conflict" = "$core_after_conflict" ]; then
  pass INST-CONFLICT-001 "same name with a different installation identity never overwrites"
else
  fail INST-CONFLICT-001 "same name with a different installation identity never overwrites"
fi

effect_home="$work/effect-home"
init_home "$effect_home"
runtime_replica="$work/deny-runtime"
mkdir -p "$runtime_replica"
replica_ok=1
while IFS= read -r runtime_name; do
  if [ -z "$runtime_name" ] || [ ! -f "$repo_root/$runtime_name" ]; then
    replica_ok=0
    continue
  fi
  mkdir -p "$runtime_replica/$(dirname -- "$runtime_name")"
  cp "$repo_root/$runtime_name" "$runtime_replica/$runtime_name" || replica_ok=0
done < "$runtime_manifest"
chmod 700 "$runtime_replica/scripts/agent-lab" 2>/dev/null || replica_ok=0
if [ "$replica_ok" -eq 1 ]; then
  sed 's/^permit (/forbid (/' "$repo_root/authorization/experiment/v0alpha1/operator.cedar" \
    > "$runtime_replica/authorization/experiment/v0alpha1/operator.cedar"
fi
capture deny-preview "$runtime_replica/scripts/agent-lab" --home "$effect_home" experiment authorize install "$fixture"
deny_preview_rc="$CAPTURE_RC"
deny_preview_out="$CAPTURE_OUT"
effect_before_deny="$(state_receipt "$effect_home")" || infrastructure=1
capture deny-install "$runtime_replica/scripts/agent-lab" --home "$effect_home" experiment install "$fixture"
effect_after_deny="$(state_receipt "$effect_home")" || infrastructure=1
if [ "$replica_ok" -eq 1 ] && [ "$deny_preview_rc" -eq 1 ] \
   && jq -e '.verdict == "deny"' "$deny_preview_out" >/dev/null 2>&1 \
   && [ "$CAPTURE_RC" -eq 1 ] && [ ! -s "$CAPTURE_OUT" ] \
   && [ "$effect_before_deny" = "$effect_after_deny" ]; then
  pass INST-DENY-001 "a freshly evaluated Cedar denial leaves store and staging unchanged"
else
  fail INST-DENY-001 "a freshly evaluated Cedar denial leaves store and staging unchanged"
fi

forged="$work/forged-permit.json"
printf '%s\n' '{"verdict":"permit","installationKey":"sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"}' > "$forged"
forged_source="$work/forged-source"
mkdir "$forged_source"
cp "$fixture/experiment.cue" "$forged_source/experiment.cue"
cp "$forged" "$forged_source/decision.json"
effect_before_forge="$(state_receipt "$effect_home")" || infrastructure=1
capture forged-option "$agent_lab" --home "$effect_home" experiment install "$fixture" --decision "$forged"
forged_option_rc="$CAPTURE_RC"
capture forged-source "$agent_lab" --home "$effect_home" experiment install "$forged_source"
forged_source_rc="$CAPTURE_RC"
effect_after_forge="$(state_receipt "$effect_home")" || infrastructure=1
if [ "$forged_option_rc" -eq 2 ] && [ "$forged_source_rc" -eq 1 ] \
   && [ "$effect_before_forge" = "$effect_after_forge" ]; then
  pass INST-FORGE-001 "caller-supplied permit data is neither an option nor accepted source authority"
else
  fail INST-FORGE-001 "caller-supplied permit data is neither an option nor accepted source authority"
fi

mkdir "$effect_home/images/catalog"
printf '%s\n' '{"corrupt":"local-catalog-must-not-be-opened"}' > "$effect_home/images/catalog/current.json"
chmod 600 "$effect_home/images/catalog/current.json"
canary_bin="$work/canary-bin"
canary_marks="$work/canary-marks"
mkdir "$canary_bin" "$canary_marks"
for command in docker git curl wget zip unzip buildah podman skopeo oras; do
  printf '%s\n' '#!/bin/sh' 'set -eu' ': > "$CANARY_DIR/${0##*/}"' 'exit 97' > "$canary_bin/$command"
  chmod 700 "$canary_bin/$command"
  CANARY_DIR="$canary_marks" "$canary_bin/$command" >/dev/null 2>&1 || true
done
calibrated="$(find "$canary_marks" -type f | wc -l)"
find "$canary_marks" -type f -delete
catalog_before="$(state_receipt "$effect_home/images")" || infrastructure=1
capture canary-install env -i \
  PATH="$canary_bin:/usr/bin:/bin" LANG=C LC_ALL=C CANARY_DIR="$canary_marks" \
  AGENT_LAB_CUE_TOOL_DIR="$AGENT_LAB_CUE_TOOL_DIR" \
  AGENT_LAB_CEDAR_TOOL_DIR="$AGENT_LAB_CEDAR_TOOL_DIR" \
  "$agent_lab" --home "$effect_home" experiment install "$fixture"
catalog_after="$(state_receipt "$effect_home/images")" || infrastructure=1
if [ "$calibrated" -eq 10 ] && [ "$CAPTURE_RC" -eq 0 ] \
   && [ -z "$(find "$canary_marks" -type f -print -quit)" ] \
   && [ "$catalog_before" = "$catalog_after" ]; then
  pass INST-NOEF-001 "direct installation ignores local catalog state and invokes no forbidden effect command"
else
  fail INST-NOEF-001 "direct installation ignores local catalog state and invokes no forbidden effect command"
fi

local_home="$work/local-home"
init_home "$local_home"
subject="registry.example/operator/worker@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
capture local-add "$agent_lab" --home "$local_home" image add vendor.worker "$subject"
local_entry="$(jq -r '.entryDigest // empty' "$CAPTURE_OUT" 2>/dev/null)"
local_source="$work/local-source"
mkdir "$local_source"
sed 's#digestRef: "registry.example/team/coordinator@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"#catalogName: "vendor.worker"#' \
  "$fixture/experiment.cue" > "$local_source/experiment.cue"
capture local-install "$agent_lab" --home "$local_home" experiment install "$local_source"
local_install_rc="$CAPTURE_RC"
local_result="$CAPTURE_OUT"
local_key="$(jq -r '.installationKey // empty' "$local_result" 2>/dev/null)"
local_receipt="$(jq -r '.receiptDigest // empty' "$local_result" 2>/dev/null)"
capture local-remove "$agent_lab" --home "$local_home" image remove vendor.worker --expect "$local_entry"
local_remove_rc="$CAPTURE_RC"
local_before_retry="$(state_receipt "$local_home")" || infrastructure=1
capture local-retry "$agent_lab" --home "$local_home" experiment install "$local_source"
local_retry_rc="$CAPTURE_RC"
capture local-inspect "$agent_lab" --home "$local_home" experiment inspect first-experiment
local_inspect_rc="$CAPTURE_RC"
local_after_retry="$(state_receipt "$local_home")" || infrastructure=1
if [ "$local_install_rc" -eq 0 ] && [ "$local_remove_rc" -eq 0 ] \
   && [ "$local_retry_rc" -eq 1 ] && [ "$local_inspect_rc" -eq 0 ] \
   && jq -e --arg key "$local_key" --arg receipt "$local_receipt" \
     '.state == "installed" and .installationKey == $key and .receiptDigest == $receipt' \
     "$CAPTURE_OUT" >/dev/null 2>&1 \
   && [ "$local_before_retry" = "$local_after_retry" ]; then
  pass INST-LOCAL-001 "removed local selector blocks retry while retained installation remains inspectable"
else
  fail INST-LOCAL-001 "removed local selector blocks retry while retained installation remains inspectable"
fi

installed_source="$work/installed-runtime-source"
installed_unavailable="$work/installed-runtime-source-unavailable"
installed_prefix="$work/installed-prefix"
installed_home="$work/installed-home"
installed_candidate="$work/installed-candidate"
installed_tools="$work/installed-pinned-tools"
installed_unrelated="$work/installed-unrelated"
installed_fixture_ok=1
mkdir -p \
  "$installed_source/packaging" \
  "$installed_source/scripts" \
  "$installed_candidate" \
  "$installed_tools/cue" \
  "$installed_tools/cedar" \
  "$installed_unrelated" || installed_fixture_ok=0
while IFS= read -r runtime_name; do
  if [ -z "$runtime_name" ] || [ ! -f "$repo_root/$runtime_name" ]; then
    installed_fixture_ok=0
    continue
  fi
  mkdir -p "$installed_source/$(dirname -- "$runtime_name")" || installed_fixture_ok=0
  cp "$repo_root/$runtime_name" "$installed_source/$runtime_name" || installed_fixture_ok=0
done < "$runtime_manifest"
cp "$runtime_manifest" "$installed_source/packaging/agent-lab-local.manifest" \
  || installed_fixture_ok=0
cp "$repo_root/scripts/install-local" "$repo_root/scripts/install-local.py" \
  "$installed_source/scripts/" || installed_fixture_ok=0
cp "$fixture/experiment.cue" "$installed_candidate/experiment.cue" \
  || installed_fixture_ok=0
cp -a "$repo_root/.cache/dev/tools/cue/." "$installed_tools/cue/" \
  || installed_fixture_ok=0
cp -a "$repo_root/.cache/dev/tools/cedar/." "$installed_tools/cedar/" \
  || installed_fixture_ok=0
chmod +x "$installed_source/scripts/install-local" "$installed_source/scripts/agent-lab" \
  || installed_fixture_ok=0

installed_bundle_rc=125
installed_init_rc=125
installed_first_rc=125
installed_inspect_rc=125
installed_retry_rc=125
installed_prefix_before="unavailable"
installed_prefix_after="unavailable"
installed_home_after_first="unavailable"
installed_home_after_inspect="unavailable"
installed_home_after_retry="unavailable"
installed_bundle_out="$work/installed-bundle.out"
installed_bundle_err="$work/installed-bundle.err"
installed_init_err="$work/installed-init.err"
installed_first_out="$work/installed-first.out"
installed_first_err="$work/installed-first.err"
installed_inspect_out="$work/installed-inspect.out"
installed_inspect_err="$work/installed-inspect.err"
installed_retry_out="$work/installed-retry.out"
installed_retry_err="$work/installed-retry.err"
: > "$installed_bundle_out"
: > "$installed_bundle_err"
: > "$installed_init_err"
: > "$installed_first_out"
: > "$installed_first_err"
: > "$installed_inspect_out"
: > "$installed_inspect_err"
: > "$installed_retry_out"
: > "$installed_retry_err"

capture_installed() {
  local label="$1"
  shift
  capture "$label" env -i PATH=/usr/bin:/bin LANG=C LC_ALL=C \
    /bin/sh -c 'cd "$1" || exit 125; shift; exec "$@"' \
    agent-lab-installed "$installed_unrelated" \
    "$installed_prefix/bin/agent-lab" --home "$installed_home" "$@"
}

if [ "$installed_fixture_ok" -eq 1 ]; then
  capture installed-bundle env -i PATH=/usr/bin:/bin LANG=C LC_ALL=C \
    "$installed_source/scripts/install-local" --prefix "$installed_prefix"
  installed_bundle_rc="$CAPTURE_RC"
  installed_bundle_out="$CAPTURE_OUT"
  installed_bundle_err="$CAPTURE_ERR"
  installed_prefix_before="$(state_receipt "$installed_prefix")" || infrastructure=1
  if ! mv "$installed_source" "$installed_unavailable"; then
    installed_fixture_ok=0
    infrastructure=1
  fi

  capture_installed installed-init init
  installed_init_rc="$CAPTURE_RC"
  installed_init_err="$CAPTURE_ERR"
  if [ "$installed_init_rc" -eq 0 ]; then
    cp -a "$installed_tools/cue/." "$installed_home/cache/tools/cue/" \
      || installed_fixture_ok=0
    cp -a "$installed_tools/cedar/." "$installed_home/cache/tools/cedar/" \
      || installed_fixture_ok=0
    if [ "$installed_fixture_ok" -ne 1 ]; then
      infrastructure=1
    fi
  fi

  capture_installed installed-first experiment install "$installed_candidate"
  installed_first_rc="$CAPTURE_RC"
  installed_first_out="$CAPTURE_OUT"
  installed_first_err="$CAPTURE_ERR"
  installed_home_after_first="$(state_receipt "$installed_home")" || infrastructure=1

  capture_installed installed-inspect experiment inspect first-experiment
  installed_inspect_rc="$CAPTURE_RC"
  installed_inspect_out="$CAPTURE_OUT"
  installed_inspect_err="$CAPTURE_ERR"
  installed_home_after_inspect="$(state_receipt "$installed_home")" || infrastructure=1

  capture_installed installed-retry experiment install "$installed_candidate"
  installed_retry_rc="$CAPTURE_RC"
  installed_retry_out="$CAPTURE_OUT"
  installed_retry_err="$CAPTURE_ERR"
  installed_home_after_retry="$(state_receipt "$installed_home")" || infrastructure=1
  installed_prefix_after="$(state_receipt "$installed_prefix")" || infrastructure=1
else
  infrastructure=1
fi

installed_key="$(jq -r '.installationKey // empty' "$installed_first_out" 2>/dev/null)"
installed_receipt="$(jq -r '.receiptDigest // empty' "$installed_first_out" 2>/dev/null)"
installed_target="$(readlink -f "$installed_prefix/bin/agent-lab" 2>/dev/null || true)"
if [ "$installed_fixture_ok" -eq 1 ] \
   && [ "$installed_bundle_rc" -eq 0 ] && [ ! -s "$installed_bundle_err" ] \
   && grep -Eq '^installed:[0-9a-f]{64}$' "$installed_bundle_out" \
   && [ "$installed_init_rc" -eq 0 ] && [ ! -s "$installed_init_err" ] \
   && [ "$installed_first_rc" -eq 0 ] && [ ! -s "$installed_first_err" ] \
   && jq -e '.changed == true and .name == "first-experiment"' \
     "$installed_first_out" >/dev/null 2>&1 \
   && [ "$installed_inspect_rc" -eq 0 ] && [ ! -s "$installed_inspect_err" ] \
   && jq -e --arg key "$installed_key" --arg receipt "$installed_receipt" \
     '.state == "installed" and .name == "first-experiment" and
      .installationKey == $key and .receiptDigest == $receipt' \
     "$installed_inspect_out" >/dev/null 2>&1 \
   && [ "$installed_retry_rc" -eq 0 ] && [ ! -s "$installed_retry_err" ] \
   && jq -e --arg key "$installed_key" --arg receipt "$installed_receipt" \
     '.changed == false and .name == "first-experiment" and
      .installationKey == $key and .receiptDigest == $receipt' \
     "$installed_retry_out" >/dev/null 2>&1 \
   && [ "$installed_home_after_first" = "$installed_home_after_inspect" ] \
   && [ "$installed_home_after_first" = "$installed_home_after_retry" ] \
   && [ "$installed_prefix_before" = "$installed_prefix_after" ] \
   && [ ! -e "$installed_source" ] && [ -d "$installed_unavailable" ] \
   && [ -z "$(find "$installed_prefix" -name __pycache__ -print -quit 2>/dev/null)" ] \
   && case "$installed_target" in
        "$installed_prefix"/lib/agent-lab/releases/*/scripts/agent-lab) true ;;
        *) false ;;
      esac; then
  pass INST-RUNTIME-001 "installed runtime remains source-independent through install, inspect, and exact retry"
else
  fail INST-RUNTIME-001 "installed runtime remains source-independent through install, inspect, and exact retry"
fi

expected="$work/expected"
printf '%s\n' \
  INST-HOME-001 INST-UNKNOWN-001 INST-NAME-001 INST-PERMIT-001 INST-RECEIPT-001 \
  INST-INSPECT-001 INST-RETRY-001 INST-CONFLICT-001 INST-DENY-001 \
  INST-FORGE-001 INST-NOEF-001 INST-LOCAL-001 INST-RUNTIME-001 > "$expected"
if ! cmp -s "$expected" "$observed"; then
  printf 'INFRA install-store assertion identity drift\n' >&2
  infrastructure=1
fi

finish
