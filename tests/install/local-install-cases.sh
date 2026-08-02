#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
expected="$repo_root/tests/install/fixtures/expected-runtime-files.txt"
manifest="$repo_root/packaging/agent-lab-local.manifest"
installer="$repo_root/scripts/install-local"
work=""
cleanup_work() {
  local failed=0
  if [ -n "$work" ] && [ -e "$work" ]; then
    find "$work" -type f -delete 2>/dev/null || failed=1
    find "$work" -type l -delete 2>/dev/null || failed=1
    find "$work" -depth -type d -exec rmdir {} + 2>/dev/null || failed=1
    [ ! -e "$work" ] || failed=1
  fi
  return "$failed"
}
if ! work="$(mktemp -d)"; then
  printf 'SUMMARY assertions=0 expected=5 failures=0 infra=1\n'
  exit 125
fi
trap 'cleanup_work >/dev/null 2>&1 || true' EXIT
failures=0
pass() { printf 'PASS %s %s\n' "$1" "$2"; }
fail() { printf 'FAIL %s %s\n' "$1" "$2"; failures=$((failures + 1)); }

if [ -f "$manifest" ] && cmp -s "$expected" "$manifest"; then
  pass PKG-001 "production runtime manifest matches the independent allowlist"
else
  fail PKG-001 "production runtime manifest matches the independent allowlist"
fi

if [ -x "$installer" ]; then
  pass PKG-002 "local installer entrypoint exists"
else
  fail PKG-002 "local installer entrypoint exists"
fi

prefix="$work/prefix"
home="$work/agent-home"
install_rc=125
version_rc=125
if [ -f "$repo_root/scripts/install-local.py" ]; then
  replica="$work/source-replica"
  mkdir -p "$replica/packaging" "$replica/scripts"
  while IFS= read -r name; do
    mkdir -p "$replica/$(dirname -- "$name")"
    cp "$repo_root/$name" "$replica/$name"
  done < "$expected"
  cp "$manifest" "$replica/packaging/agent-lab-local.manifest"
  cp "$repo_root/scripts/install-local" "$repo_root/scripts/install-local.py" "$replica/scripts/"
  chmod +x "$replica/scripts/install-local" "$replica/scripts/agent-lab"
  install_rc=0
  "$replica/scripts/install-local" --prefix "$prefix" > "$work/install.out" 2> "$work/install.err" || install_rc=$?
  cp -R "$repo_root/tests/experiment/fixtures/directories/minimal" "$work/artifact"
  mv "$replica" "$work/source-unavailable"
  mkdir "$work/unrelated"
  version_rc=0
  (cd "$work/unrelated" && env -i PATH=/usr/bin:/bin "$prefix/bin/agent-lab" --home "$home" version) \
    > "$work/version.out" 2> "$work/version.err" || version_rc=$?
fi
if [ "$install_rc" -eq 0 ] && [ "$version_rc" -eq 0 ] &&
   grep -Fxq 'agent-lab v0alpha1' "$work/version.out" && [ ! -s "$work/version.err" ]; then
  pass PKG-003 "installed CLI runs after its isolated source replica is unavailable"
else
  fail PKG-003 "installed CLI runs after its isolated source replica is unavailable"
fi

check_rc=125
if [ "$install_rc" -eq 0 ] && [ "$version_rc" -eq 0 ]; then
  "$prefix/bin/agent-lab" --home "$home" init > "$work/init.out" 2> "$work/init.err"
  cp -a "$repo_root/.cache/dev/tools/cue/." "$home/cache/tools/cue/"
  cp -a "$repo_root/.cache/dev/tools/cedar/." "$home/cache/tools/cedar/"
  check_rc=0
  (cd "$work/unrelated" && env -i PATH=/usr/bin:/bin "$prefix/bin/agent-lab" --home "$home" experiment check "$work/artifact") \
    > "$work/check.out" 2> "$work/check.err" || check_rc=$?
fi
if [ "$check_rc" -eq 0 ] && [ ! -s "$work/check.err" ] &&
   jq -e '.source.kind == "directory" and .plan.kind == "RequestedExperimentPlan"' "$work/check.out" >/dev/null 2>&1; then
  pass PKG-004 "installed Experiment check is independent of the source checkout"
else
  fail PKG-004 "installed Experiment check is independent of the source checkout"
  printf 'PKG-004 rc=%s stderr=%s\n' "$check_rc" "$(tr '\n' ' ' < "$work/check.err" 2>/dev/null || true)"
fi

mkdir "$work/symlink-target"
ln -s "$work/symlink-target" "$work/symlink-prefix"
symlink_rc=0
"$installer" --prefix "$work/symlink-prefix" > "$work/symlink.out" 2> "$work/symlink.err" || symlink_rc=$?
if [ "$symlink_rc" -eq 125 ] && [ -z "$(find "$work/symlink-target" -mindepth 1 -print -quit)" ]; then
  pass PKG-005 "installer refuses a symlinked prefix before writes"
else
  fail PKG-005 "installer refuses a symlinked prefix before writes"
fi

infrastructure=0
if ! cleanup_work; then
  infrastructure=1
fi
trap - EXIT
printf 'SUMMARY assertions=5 expected=5 failures=%s infra=%s\n' "$failures" "$infrastructure"
if [ "$infrastructure" -ne 0 ]; then
  exit 125
fi
[ "$failures" -eq 0 ]
