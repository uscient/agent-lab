#!/usr/bin/env bash
set -u -o pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
agent_lab="$repo_root/scripts/agent-lab"
work="$(mktemp -d)"
trap 'find "$work" -type f -delete 2>/dev/null || true; find "$work" -type l -delete 2>/dev/null || true; find "$work" -depth -type d -exec rmdir {} + 2>/dev/null || true' EXIT

if [ ! -x "$agent_lab" ] || ! command -v jq >/dev/null 2>&1 || [ ! -d "$repo_root/.cache/dev/tools/cue" ]; then
  printf 'INFRA catalog resolution prerequisites are unavailable\n' >&2
  exit 125
fi

failures=0
observed="$work/observed"
: > "$observed"
pass() { printf 'PASS %s %s\n' "$1" "$2"; printf '%s\n' "$1" >> "$observed"; }
fail() { printf 'FAIL %s %s\n' "$1" "$2"; printf '%s\n' "$1" >> "$observed"; failures=$((failures + 1)); }
capture() { CAPTURE_RC=0; "$@" > "$work/stdout" 2> "$work/stderr" || CAPTURE_RC=$?; }
subject_a="registry.example/operator/worker@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
subject_b="registry.example/operator/other@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

init_home() {
  local home="$1"
  capture "$agent_lab" --home "$home" init
  if [ "$CAPTURE_RC" -ne 0 ]; then
    printf 'INFRA temporary Agent Lab home initialization failed: %s\n' "$(tr '\n' ' ' < "$work/stderr")" >&2
    exit 125
  fi
  cp -a "$repo_root/.cache/dev/tools/cue/." "$home/cache/tools/cue/"
}

copy_cedar() {
  local home="$1"
  if [ ! -d "$repo_root/.cache/dev/tools/cedar" ]; then
    printf 'INFRA pinned Cedar test cache is unavailable\n' >&2
    exit 125
  fi
  cp -a "$repo_root/.cache/dev/tools/cedar/." "$home/cache/tools/cedar/"
}

write_artifact() {
  local directory="$1"
  local experiment_name="$2"
  local selector_key="$3"
  local selector_value="$4"
  mkdir -p "$directory"
  printf '%s\n' \
    'package experiment' \
    '' \
    'experiment: {' \
    '  apiVersion: "agent-lab/v0alpha1"' \
    '  kind:       "Experiment"' \
    "  metadata: name: \"$experiment_name\"" \
    '  spec: members: [{' \
    '    name: "worker"' \
    "    image: $selector_key: \"$selector_value\"" \
    '  }]' \
    '}' > "$directory/experiment.cue"
}

write_two_member_artifact() {
  local directory="$1"
  mkdir -p "$directory"
  printf '%s\n' \
    'package experiment' \
    '' \
    'experiment: {' \
    '  apiVersion: "agent-lab/v0alpha1"' \
    '  kind:       "Experiment"' \
    '  metadata: name: "two-members"' \
    '  spec: members: [{' \
    '    name: "first"' \
    '    image: catalogName: "vendor.worker"' \
    '  }, {' \
    '    name: "second"' \
    '    image: catalogName: "vendor.second"' \
    '  }]' \
    '}' > "$directory/experiment.cue"
}

active_home="$work/active-home"
init_home "$active_home"
capture "$agent_lab" --home "$active_home" image add vendor.worker "$subject_a"
if [ "$CAPTURE_RC" -ne 0 ]; then
  printf 'INFRA active local mapping setup failed\n' >&2
  exit 125
fi
entry_a="$(jq -r '.entryDigest' "$work/stdout")"
artifact="$work/active-artifact"
write_artifact "$artifact" local-active catalogName vendor.worker
capture "$agent_lab" --home "$active_home" experiment check "$artifact"
active_rc="$CAPTURE_RC"
cp "$work/stdout" "$work/active-check.json"
if [ "$active_rc" -eq 0 ] && jq -e --arg entry "$entry_a" --arg subject "$subject_a" '
  .plan.spec.members[0].resolvedImage == {
    entryDigest: $entry,
    generation: 1,
    origin: "local",
    subject: $subject
  }
' "$work/active-check.json" >/dev/null 2>&1; then
  pass RES-ENTRY-001 "active local resolution binds exact entry identity and immutable subject"
else
  fail RES-ENTRY-001 "active local resolution binds exact entry identity and immutable subject"
fi

snapshot_digest="$(jq -r '.snapshotDigest' "$active_home/images/catalog/current.json" 2>/dev/null)"
snapshot_revision="$(jq -r '.revision' "$active_home/images/catalog/snapshots/${snapshot_digest#sha256:}.json" 2>/dev/null)"
if [ "$active_rc" -eq 0 ] && jq -e --arg digest "$snapshot_digest" --argjson revision "$snapshot_revision" '
  .catalog.local == {revision: $revision, snapshotDigest: $digest}
' "$work/active-check.json" >/dev/null 2>&1; then
  pass RES-SNAP-001 "checked evidence records the exact held local snapshot revision and digest"
else
  fail RES-SNAP-001 "checked evidence records the exact held local snapshot revision and digest"
fi

first_plan_digest="$(jq -r '.digest // empty' "$work/active-check.json" 2>/dev/null)"
capture "$agent_lab" --home "$active_home" image add vendor.unrelated "$subject_b"
capture "$agent_lab" --home "$active_home" experiment check "$artifact"
cp "$work/stdout" "$work/unrelated-check.json"
second_snapshot_digest="$(jq -r '.snapshotDigest' "$active_home/images/catalog/current.json" 2>/dev/null)"
if [ "$CAPTURE_RC" -eq 0 ] &&
   [ "$first_plan_digest" = "$(jq -r '.digest // empty' "$work/unrelated-check.json" 2>/dev/null)" ] &&
   [ "$snapshot_digest" != "$second_snapshot_digest" ] &&
   jq -e --arg digest "$second_snapshot_digest" '.catalog.local.snapshotDigest == $digest' "$work/unrelated-check.json" >/dev/null 2>&1; then
  pass RES-SNAP-002 "unrelated catalog mutation changes snapshot evidence but not selected-entry plan identity"
else
  fail RES-SNAP-002 "unrelated catalog mutation changes snapshot evidence but not selected-entry plan identity"
fi

other_home="$work/other-home"
init_home "$other_home"
capture "$agent_lab" --home "$other_home" image add vendor.worker "$subject_b"
entry_b="$(jq -r '.entryDigest // empty' "$work/stdout" 2>/dev/null)"
capture "$agent_lab" --home "$other_home" experiment check "$artifact"
if [ "$CAPTURE_RC" -eq 0 ] && [ "$entry_a" != "$entry_b" ] &&
   [ "$first_plan_digest" != "$(jq -r '.digest // empty' "$work/stdout" 2>/dev/null)" ]; then
  pass RES-ENTRY-002 "substituting the selected entry changes plan identity"
else
  fail RES-ENTRY-002 "substituting the selected entry changes plan identity"
fi

unknown_artifact="$work/unknown-artifact"
write_artifact "$unknown_artifact" local-unknown catalogName vendor.unknown
capture "$agent_lab" --home "$active_home" experiment check "$unknown_artifact"
unknown_rc="$CAPTURE_RC"
removed_home="$work/removed-home"
init_home "$removed_home"
capture "$agent_lab" --home "$removed_home" image add vendor.worker "$subject_a"
removed_entry="$(jq -r '.entryDigest // empty' "$work/stdout" 2>/dev/null)"
capture "$agent_lab" --home "$removed_home" image remove vendor.worker --expect "$removed_entry"
capture "$agent_lab" --home "$removed_home" experiment check "$artifact"
removed_rc="$CAPTURE_RC"
if [ "$unknown_rc" -eq 1 ] && [ "$removed_rc" -eq 1 ]; then
  pass RES-ENTRY-003 "unknown and tombstoned local names are stable invalid input"
else
  fail RES-ENTRY-003 "unknown and tombstoned local names are stable invalid input"
fi

isolation_home="$work/isolation-home"
init_home "$isolation_home"
mkdir "$isolation_home/images/catalog"
printf '{"snapshotDigest":"sha256:%064d"}\n' 0 > "$isolation_home/images/catalog/current.json"
direct_artifact="$work/direct-artifact"
write_artifact "$direct_artifact" direct-isolated digestRef "$subject_a"
capture "$agent_lab" --home "$isolation_home" experiment check "$direct_artifact"
direct_rc="$CAPTURE_RC"
direct_has_local="$(jq -r 'has("catalog") and (.catalog | has("local"))' "$work/stdout" 2>/dev/null || printf invalid)"
bundled_artifact="$work/bundled-artifact"
write_artifact "$bundled_artifact" bundled-isolated catalogName agent-lab.unknown
capture "$agent_lab" --home "$isolation_home" experiment check "$bundled_artifact"
bundled_rc="$CAPTURE_RC"
if [ "$direct_rc" -eq 0 ] && [ "$direct_has_local" = false ] && [ "$bundled_rc" -eq 1 ]; then
  pass RES-ISOLATE-001 "corrupt local state cannot block or contaminate direct and bundled selectors"
else
  fail RES-ISOLATE-001 "corrupt local state cannot block or contaminate direct and bundled selectors"
fi

history_home="$work/history-home"
init_home "$history_home"
capture "$agent_lab" --home "$history_home" image add vendor.worker "$subject_a"
mv "$history_home/images/catalog/entries" "$work/removed-resolution-history"
capture "$agent_lab" --home "$history_home" experiment check "$artifact"
if [ "$CAPTURE_RC" -eq 125 ] && [ ! -s "$work/stdout" ]; then
  pass RES-STATE-001 "local resolution verifies immutable entry history before binding"
else
  fail RES-STATE-001 "local resolution verifies immutable entry history before binding"
fi

drift_home="$work/drift-home"
init_home "$drift_home"
capture "$agent_lab" --home "$drift_home" image add vendor.worker "$subject_a"
mkdir "$drift_home/other-images"
mv "$drift_home/images/catalog" "$drift_home/other-images/catalog"
jq -cS '.paths.images="other-images"' "$drift_home/config.json" > "$work/drift-config.json"
mv "$work/drift-config.json" "$drift_home/config.json"
chmod 600 "$drift_home/config.json"
capture "$agent_lab" --home "$drift_home" config check
drift_config_rc="$CAPTURE_RC"
capture "$agent_lab" --home "$drift_home" experiment check "$artifact"
if [ "$drift_config_rc" -eq 125 ] && [ "$CAPTURE_RC" -eq 125 ] && [ ! -s "$work/stdout" ]; then
  pass RES-STATE-002 "receipt-breaking config drift cannot redirect local resolution"
else
  fail RES-STATE-002 "receipt-breaking config drift cannot redirect local resolution"
fi

symlink_source="$work/symlink-source"
init_home "$symlink_source"
capture "$agent_lab" --home "$symlink_source" image add vendor.worker "$subject_a"
mv "$symlink_source/images/catalog" "$work/outside-resolution-catalog"
symlink_home="$work/symlink-home"
init_home "$symlink_home"
ln -s "$work/outside-resolution-catalog" "$symlink_home/images/catalog"
capture "$agent_lab" --home "$symlink_home" experiment check "$artifact"
if [ "$CAPTURE_RC" -eq 125 ] && [ ! -s "$work/stdout" ]; then
  pass RES-STATE-003 "local resolution refuses a symlinked catalog authority"
else
  fail RES-STATE-003 "local resolution refuses a symlinked catalog authority"
fi

supplied="$work/supplied-fields"
mkdir "$supplied"
printf '%s\n' \
  'package experiment' \
  '' \
  'experiment: {' \
  '  apiVersion: "agent-lab/v0alpha1"' \
  '  kind:       "Experiment"' \
  '  metadata: name: "supplied-fields"' \
  '  spec: members: [{' \
  '    name: "worker"' \
  '    image: {' \
  '      catalogName: "vendor.worker"' \
  '      resolvedSubject: "registry.example/evil@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"' \
  '    }' \
  '  }]' \
  '}' > "$supplied/experiment.cue"
capture "$agent_lab" --home "$active_home" experiment check "$supplied"
if [ "$CAPTURE_RC" -eq 1 ] && [ ! -s "$work/stdout" ]; then
  pass RES-INPUT-001 "Experiment content cannot supply catalog source, entry, or resolved-subject authority"
else
  fail RES-INPUT-001 "Experiment content cannot supply catalog source, entry, or resolved-subject authority"
fi

multi_home="$work/multi-home"
init_home "$multi_home"
capture "$agent_lab" --home "$multi_home" image add vendor.worker "$subject_a"
multi_entry_a="$(jq -r '.entryDigest // empty' "$work/stdout" 2>/dev/null)"
capture "$agent_lab" --home "$multi_home" image add vendor.second "$subject_b"
multi_entry_b="$(jq -r '.entryDigest // empty' "$work/stdout" 2>/dev/null)"
multi_digest="$(jq -r '.snapshotDigest' "$multi_home/images/catalog/current.json" 2>/dev/null)"
multi_artifact="$work/multi-artifact"
write_two_member_artifact "$multi_artifact"
capture "$agent_lab" --home "$multi_home" experiment check "$multi_artifact"
if [ "$CAPTURE_RC" -eq 0 ] && jq -e --arg first "$multi_entry_a" --arg second "$multi_entry_b" --arg snapshot "$multi_digest" '
  .plan.spec.members[0].resolvedImage.entryDigest == $first and
  .plan.spec.members[1].resolvedImage.entryDigest == $second and
  .catalog.local.snapshotDigest == $snapshot
' "$work/stdout" >/dev/null 2>&1; then
  pass RES-SNAP-003 "all local members bind entries from one held catalog snapshot"
else
  fail RES-SNAP-003 "all local members bind entries from one held catalog snapshot"
fi

copy_cedar "$active_home"
capture "$agent_lab" --home "$active_home" experiment authorize install "$artifact"
if [ "$CAPTURE_RC" -eq 0 ] && jq -e --arg plan "$first_plan_digest" '.verdict == "permit" and .binding.planDigest == $plan' "$work/stdout" >/dev/null 2>&1; then
  pass RES-AUTH-001 "fresh authorization binds the selected-entry plan digest"
else
  fail RES-AUTH-001 "fresh authorization binds the selected-entry plan digest"
fi

installed_prefix="$work/installed-prefix"
installed_home="$work/installed-home"
runtime_replica="$work/runtime-replica"
runtime_manifest="$repo_root/packaging/agent-lab-local.manifest"
mkdir -p "$runtime_replica/packaging" "$runtime_replica/scripts"
while IFS= read -r runtime_name; do
  mkdir -p "$runtime_replica/$(dirname -- "$runtime_name")"
  cp "$repo_root/$runtime_name" "$runtime_replica/$runtime_name"
done < "$runtime_manifest"
cp "$runtime_manifest" "$runtime_replica/packaging/agent-lab-local.manifest"
cp "$repo_root/scripts/install-local" "$repo_root/scripts/install-local.py" "$runtime_replica/scripts/"
chmod +x "$runtime_replica/scripts/install-local" "$runtime_replica/scripts/agent-lab"
capture "$runtime_replica/scripts/install-local" --prefix "$installed_prefix"
installed_install_rc="$CAPTURE_RC"
mv "$runtime_replica" "$work/runtime-source-unavailable"
mkdir "$work/installed-unrelated"
installed_rc=125
if [ "$installed_install_rc" -eq 0 ]; then
  capture "$installed_prefix/bin/agent-lab" --home "$installed_home" init
  cp -a "$repo_root/.cache/dev/tools/cue/." "$installed_home/cache/tools/cue/"
  capture "$installed_prefix/bin/agent-lab" --home "$installed_home" image add vendor.worker "$subject_a"
  installed_entry="$(jq -r '.entryDigest // empty' "$work/stdout" 2>/dev/null)"
  installed_rc=0
  (cd "$work/installed-unrelated" && env -i PATH=/usr/bin:/bin \
    "$installed_prefix/bin/agent-lab" --home "$installed_home" experiment check "$artifact") \
    > "$work/installed-check.json" 2> "$work/installed-check.err" || installed_rc=$?
else
  installed_entry=""
fi
if [ "$installed_install_rc" -eq 0 ] && [ "$installed_rc" -eq 0 ] &&
   [ ! -s "$work/installed-check.err" ] && jq -e --arg entry "$installed_entry" --arg subject "$subject_a" '
     .plan.spec.members[0].resolvedImage == {
       entryDigest: $entry,
       generation: 1,
       origin: "local",
       subject: $subject
     }
   ' "$work/installed-check.json" >/dev/null 2>&1; then
  pass RES-INSTALL-001 "installed catalog commands and local resolution run without the source replica or checkout cwd"
else
  fail RES-INSTALL-001 "installed catalog commands and local resolution run without the source replica or checkout cwd"
fi

canary_home="$work/canary-home"
init_home "$canary_home"
capture "$agent_lab" --home "$canary_home" image add vendor.worker "$subject_a"
canary_bin="$work/canary-bin"
canary_marks="$work/canary-marks"
mkdir "$canary_bin" "$canary_marks"
for command in docker git curl wget; do
  printf '%s\n' '#!/bin/sh' 'set -eu' ': > "$CANARY_DIR/${0##*/}"' > "$canary_bin/$command"
  chmod 700 "$canary_bin/$command"
  CANARY_DIR="$canary_marks" "$canary_bin/$command"
done
calibrated="$(find "$canary_marks" -type f | wc -l)"
find "$canary_marks" -type f -delete
canary_rc=0
env -i PATH="$canary_bin:/usr/bin:/bin" LANG=C LC_ALL=C CANARY_DIR="$canary_marks" \
  "$agent_lab" --home "$canary_home" experiment check "$artifact" > "$work/canary.out" 2> "$work/canary.err" || canary_rc=$?
if [ "$calibrated" -eq 4 ] && [ "$canary_rc" -eq 0 ] && [ -z "$(find "$canary_marks" -type f -print -quit)" ]; then
  pass RES-NOEF-001 "calibrated forbidden-effect canaries remain silent during local resolution"
else
  fail RES-NOEF-001 "calibrated forbidden-effect canaries remain silent during local resolution"
fi

expected="$work/expected"
printf '%s\n' \
  RES-ENTRY-001 RES-SNAP-001 RES-SNAP-002 RES-ENTRY-002 RES-ENTRY-003 \
  RES-ISOLATE-001 RES-STATE-001 RES-STATE-002 RES-STATE-003 RES-INPUT-001 \
  RES-SNAP-003 RES-AUTH-001 RES-INSTALL-001 RES-NOEF-001 > "$expected"
if ! cmp -s "$expected" "$observed"; then
  printf 'INFRA catalog resolution assertion identity drift\n' >&2
  exit 125
fi
printf 'SUMMARY assertions=14 expected=14 failures=%s infra=0\n' "$failures"
[ "$failures" -eq 0 ]
