#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
command_path="$repo_root/scripts/dev/workstream"
work="$(mktemp -d)"
trap 'find "$work" -depth -delete >/dev/null 2>&1 || true' EXIT
failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

if [ -x "$command_path" ]; then
  pass "workstream command exists and is executable"
else
  fail "workstream command exists and is executable"
  printf 'SUMMARY failures=%s\n' "$failures"
  exit 1
fi

fake_bin="$work/bin"
mkdir -p "$fake_bin"
gh_log="$work/gh.log"
cat > "$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$WORKSTREAM_GH_LOG"
case "$1 $2" in
  "pr view") printf '%s\n' "$WORKSTREAM_PR_JSON" ;;
  "pr merge") exit 0 ;;
  "pr create") exit 0 ;;
  *) exit 99 ;;
esac
EOF
chmod +x "$fake_bin/gh"

valid_json='{"number":17,"state":"OPEN","isDraft":false,"baseRefName":"work/demo","headRefName":"slice/demo/format","headRefOid":"0123456789abcdef0123456789abcdef01234567","mergeStateStatus":"CLEAN","reviewDecision":"","statusCheckRollup":[{"name":"Fast","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"Required gates","status":"COMPLETED","conclusion":"SUCCESS"}]}'

route_fixture="$work/route"
mkdir -p "$route_fixture/scripts/dev"
cp "$command_path" "$route_fixture/scripts/dev/workstream"
git -C "$route_fixture" init -q
git -C "$route_fixture" symbolic-ref HEAD refs/heads/slice/demo/format
: > "$gh_log"
if PATH="$fake_bin:/usr/bin:/bin" WORKSTREAM_GH_LOG="$gh_log" \
  "$route_fixture/scripts/dev/workstream" pr --title format --body body >/dev/null \
  && grep -Fxq 'pr create --base work/demo --head slice/demo/format --title format --body body' "$gh_log"; then
  pass "slice PR routing derives the matching workstream base"
else
  fail "slice PR routing derives the matching workstream base"
fi
if PATH="$fake_bin:/usr/bin:/bin" WORKSTREAM_GH_LOG="$gh_log" \
  "$route_fixture/scripts/dev/workstream" pr --base dev --title bad >/dev/null 2>&1; then
  fail "slice PR routing rejects caller-selected authority"
else
  pass "slice PR routing rejects caller-selected authority"
fi
git -C "$route_fixture" symbolic-ref HEAD refs/heads/work/demo
: > "$gh_log"
if PATH="$fake_bin:/usr/bin:/bin" WORKSTREAM_GH_LOG="$gh_log" \
  "$route_fixture/scripts/dev/workstream" final --title complete --body body >/dev/null \
  && grep -Fxq 'pr create --base dev --head work/demo --draft --title complete --body body' "$gh_log"; then
  pass "final PR routing is fixed to dev and remains draft"
else
  fail "final PR routing is fixed to dev and remains draft"
fi

run_merge() {
  local json="$1" candidate="${2:-$command_path}" rc=0
  : > "$gh_log"
  PATH="$fake_bin:/usr/bin:/bin" WORKSTREAM_GH_LOG="$gh_log" WORKSTREAM_PR_JSON="$json" \
    "$candidate" merge 17 >"$work/stdout" 2>"$work/stderr" || rc=$?
  return "$rc"
}

if run_merge "$valid_json" \
  && grep -Fxq 'pr merge 17 --merge --match-head-commit 0123456789abcdef0123456789abcdef01234567' "$gh_log"; then
  pass "green matching slice PR is merged with its observed head commit"
else
  fail "green matching slice PR is merged with its observed head commit"
fi

for field_case in \
  'wrong-base|"baseRefName":"work/other"' \
  'wrong-head|"headRefName":"slice/other/format"' \
  'draft|"isDraft":true' \
  'changes-requested|"reviewDecision":"CHANGES_REQUESTED"' \
  'dirty|"mergeStateStatus":"DIRTY"' \
  'pending|"status":"IN_PROGRESS"' \
  'failed|"conclusion":"FAILURE"' \
  'skipped|"conclusion":"SKIPPED"'; do
  name="${field_case%%|*}"
  replacement="${field_case#*|}"
  case "$name" in
    wrong-base) mutated="${valid_json/\"baseRefName\":\"work\/demo\"/$replacement}" ;;
    wrong-head) mutated="${valid_json/\"headRefName\":\"slice\/demo\/format\"/$replacement}" ;;
    draft) mutated="${valid_json/\"isDraft\":false/$replacement}" ;;
    changes-requested) mutated="${valid_json/\"reviewDecision\":\"\"/$replacement}" ;;
    dirty) mutated="${valid_json/\"mergeStateStatus\":\"CLEAN\"/$replacement}" ;;
    pending) mutated="${valid_json/\"status\":\"COMPLETED\"/$replacement}" ;;
    failed) mutated="${valid_json/\"conclusion\":\"SUCCESS\"/$replacement}" ;;
    skipped) mutated="${valid_json/\"conclusion\":\"SUCCESS\"/$replacement}" ;;
  esac
  if run_merge "$mutated"; then
    fail "$name PR state blocks integration"
  elif ! grep -q '^pr merge ' "$gh_log"; then
    pass "$name PR state blocks integration"
  else
    fail "$name PR state blocks integration"
  fi
done

empty_checks="$(printf '%s' "$valid_json" | jq -c '.statusCheckRollup = []')"
if run_merge "$empty_checks"; then
  fail "missing checks block integration"
elif ! grep -q '^pr merge ' "$gh_log"; then
  pass "missing checks block integration"
else
  fail "missing checks block integration"
fi

mutant="$work/mutant/scripts/dev/workstream"
mkdir -p "${mutant%/*}"
sed 's/(all(\.statusCheckRollup\[\]; \.status == "COMPLETED" and \.conclusion == "SUCCESS"))/(true)/' \
  "$command_path" > "$mutant"
chmod +x "$mutant"
if [ "$(cmp -s "$command_path" "$mutant"; printf '%s' "$?")" -ne 0 ] \
  && run_merge "${valid_json/\"conclusion\":\"SUCCESS\"/\"conclusion\":\"FAILURE\"}" "$mutant"; then
  pass "all-checks sensitivity mutation turns RED"
else
  fail "all-checks sensitivity mutation turns RED"
fi

printf 'SUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
