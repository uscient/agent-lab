#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
agent_lab="$repo_root/scripts/agent-lab"
fixture="$repo_root/tests/experiment/fixtures/directories/minimal"
work="$(mktemp -d)"
trap 'find "$work" -type f -delete 2>/dev/null || true; find "$work" -depth -type d -exec rmdir {} + 2>/dev/null || true' EXIT
mkdir -p "$work/home" "$work/tmp"

if ! python3 -I -B "$repo_root/tests/experiment/zip-fixtures.py" \
  "$fixture/experiment.cue" "$work"; then
  printf 'SUMMARY assertions=0 expected=16 failures=0 infra=1\n'
  exit 125
fi

capture() {
  local name="$1"
  shift
  CAPTURE_RC=0
  env -i PATH=/usr/bin:/bin HOME="$work/home" TMPDIR="$work/tmp" LC_ALL=C \
    AGENT_LAB_CUE_TOOL_DIR="${AGENT_LAB_CUE_TOOL_DIR:-$repo_root/.cache/dev/tools/cue}" \
    "$@" > "$work/$name.out" 2> "$work/$name.err" || CAPTURE_RC=$?
}

failures=0
observed="$work/observed"
: > "$observed"
pass() { printf 'PASS %s %s\n' "$1" "$2"; printf '%s\n' "$1" >> "$observed"; }
fail() { printf 'FAIL %s %s\n' "$1" "$2"; printf '%s\n' "$1" >> "$observed"; failures=$((failures + 1)); }
expect_all_reject() {
  local id="$1" code="$2" detail="$3"
  shift 3
  local archive accepted=0
  for archive in "$@"; do
    capture "reject-${archive%.zip}" "$agent_lab" experiment check --zip "$work/$archive"
    if [ "$CAPTURE_RC" -ne 1 ] || [ -s "$work/reject-${archive%.zip}.out" ] ||
       [ "$(wc -l < "$work/reject-${archive%.zip}.err")" -ne 1 ] ||
       ! grep -Fq "FAIL Experiment manifest zip archive $code" \
         "$work/reject-${archive%.zip}.err"; then
      accepted=1
    fi
  done
  if [ "$accepted" -eq 0 ]; then
    pass "$id" "$detail"
  else
    fail "$id" "$detail"
  fi
}

capture directory "$agent_lab" experiment check "$fixture"
directory_rc="$CAPTURE_RC"
capture stored "$agent_lab" experiment check --zip "$work/stored.zip"
stored_rc="$CAPTURE_RC"
capture deflated "$agent_lab" experiment check --zip "$work/deflated.zip"
deflated_rc="$CAPTURE_RC"

if [ "$directory_rc" -eq 0 ] && [ "$stored_rc" -eq 0 ] && [ "$deflated_rc" -eq 0 ] &&
   [ ! -s "$work/directory.err" ] && [ ! -s "$work/stored.err" ] &&
   [ ! -s "$work/deflated.err" ] &&
   [ "$(jq -cS '.plan' "$work/directory.out")" = "$(jq -cS '.plan' "$work/stored.out")" ] &&
   [ "$(jq -cS '.plan' "$work/directory.out")" = "$(jq -cS '.plan' "$work/deflated.out")" ] &&
   [ "$(jq -r '.source.digest' "$work/directory.out")" = "$(jq -r '.source.digest' "$work/stored.out")" ] &&
   [ "$(jq -r '.source.digest' "$work/directory.out")" = "$(jq -r '.source.digest' "$work/deflated.out")" ] &&
   jq -e '.source.kind == "zip" and (.source.archiveDigest | startswith("sha256:"))' \
     "$work/stored.out" >/dev/null 2>&1 &&
   jq -e '.source.kind == "zip" and (.source.archiveDigest | startswith("sha256:"))' \
     "$work/deflated.out" >/dev/null 2>&1; then
  pass ZIP-001 "public zip check normalizes stored and deflated sources"
else
  fail ZIP-001 "public zip check normalizes stored and deflated sources"
fi

expect_all_reject ZIP-PATH-001 ZIP-PATH "only the exact ASCII root member name is accepted" \
  wrong-case.zip wrapper.zip dotdot.zip backslash.zip absolute.zip drive.zip unc.zip \
  nul-name.zip control-name.zip nonascii.zip

expect_all_reject ZIP-COUNT-001 ZIP-COUNT "the archive has exactly one member" \
  zero-count.zip extra-entry.zip duplicate.zip

expect_all_reject ZIP-TYPE-001 ZIP-TYPE "the sole member is a regular file" \
  directory-type.zip symlink-type.zip fifo-type.zip

expect_all_reject ZIP-META-001 ZIP-META "member and archive metadata are closed" \
  extra-field.zip file-comment.zip archive-comment.zip

expect_all_reject ZIP-FLAG-001 ZIP-FLAG "encrypted and descriptor-based members are refused" \
  encrypted.zip strong-encrypted.zip data-descriptor.zip

expect_all_reject ZIP-METHOD-001 ZIP-METHOD "only stored and raw deflate members are accepted" \
  unsupported-method.zip

expect_all_reject ZIP-ZIP64-001 ZIP-ZIP64 "ZIP64 and multidisk records are refused" \
  zip64-version.zip zip64-sentinel.zip multidisk.zip

expect_all_reject ZIP-HEADER-001 ZIP-HEADER "central and local headers agree exactly" \
  central-signature.zip central-name-mismatch.zip central-flags-mismatch.zip

expect_all_reject ZIP-CRC-001 ZIP-CRC "member CRC is verified" bad-crc.zip

expect_all_reject ZIP-LENGTH-001 ZIP-LENGTH "declared and decoded lengths agree" \
  bad-length.zip

expect_all_reject ZIP-SIZE-001 ZIP-SIZE "archive and expanded source bounds apply before planning" \
  archive-over.zip expanded-over.zip deflate-bomb.zip

expect_all_reject ZIP-BOMB-001 ZIP-BOMB "declared-small deflate expansion stops at the source bound" \
  declared-small-large.zip

expect_all_reject ZIP-TRUNC-001 ZIP-TRUNC "truncated records and deflate streams are refused" \
  missing-central.zip truncated-deflate.zip

expect_all_reject ZIP-TRAIL-001 ZIP-TRAIL "bytes after the canonical archive end are refused" trailing.zip

ln -s "$work/stored.zip" "$work/archive-link.zip"
mkdir "$work/archive-directory"
capture missing "$agent_lab" experiment check --zip "$work/missing.zip"
missing_rc="$CAPTURE_RC"
capture linked "$agent_lab" experiment check --zip "$work/archive-link.zip"
linked_rc="$CAPTURE_RC"
capture archive-directory "$agent_lab" experiment check --zip "$work/archive-directory"
directory_path_rc="$CAPTURE_RC"
if [ "$missing_rc" -eq 125 ] && [ "$linked_rc" -eq 125 ] &&
   [ "$directory_path_rc" -eq 125 ] && [ ! -s "$work/missing.out" ] &&
   [ ! -s "$work/linked.out" ] && [ ! -s "$work/archive-directory.out" ]; then
  pass ZIP-READ-001 "unavailable or unsafe archive paths are infrastructure failures"
else
  fail ZIP-READ-001 "unavailable or unsafe archive paths are infrastructure failures"
fi

expected="$work/expected"
printf '%s\n' \
  ZIP-001 ZIP-PATH-001 ZIP-COUNT-001 ZIP-TYPE-001 ZIP-META-001 \
  ZIP-FLAG-001 ZIP-METHOD-001 ZIP-ZIP64-001 ZIP-HEADER-001 ZIP-CRC-001 \
  ZIP-LENGTH-001 ZIP-SIZE-001 ZIP-BOMB-001 ZIP-TRUNC-001 ZIP-TRAIL-001 \
  ZIP-READ-001 > "$expected"
if ! cmp -s "$expected" "$observed"; then
  printf 'INFRA assertion identity drift\n' >&2
  exit 125
fi
printf 'SUMMARY assertions=16 expected=16 failures=%s infra=0\n' "$failures"
[ "$failures" -eq 0 ]
