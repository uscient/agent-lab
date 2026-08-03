#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
command_path="$repo_root/scripts/dev/workstream"
work="$(mktemp -d)"
trap 'find "$work" -depth -delete >/dev/null 2>&1 || true' EXIT
failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }
infra() { printf 'INFRA %s\n' "$1" >&2; exit 125; }

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
merged_marker="$work/merged"
cat > "$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$WORKSTREAM_GH_LOG"
case "$1 $2" in
  "repo view") printf '%s\n' 'uscient/agent-lab' ;;
  "pr view")
    if [[ "$*" == *'--json state --jq .state'* ]] && [ -f "$WORKSTREAM_MERGED_MARKER" ]; then
      printf '%s\n' MERGED
    elif [ -n "${WORKSTREAM_UPDATED_BODY:-}" ] && [ -f "$WORKSTREAM_UPDATED_BODY" ]; then
      /usr/bin/jq -c --rawfile body "$WORKSTREAM_UPDATED_BODY" '.body = $body' \
        <<<"$WORKSTREAM_PR_JSON"
    else
      printf '%s\n' "$WORKSTREAM_PR_JSON"
    fi
    ;;
  "pr merge") exit 96 ;;
  "pr edit")
    body_file=""
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --body-file ] && [ "$#" -gt 1 ]; then body_file="$2"; shift; fi
      shift
    done
    [ -n "$body_file" ] && [ -n "${WORKSTREAM_UPDATED_BODY:-}" ] || exit 98
    /usr/bin/cp "$body_file" "$WORKSTREAM_UPDATED_BODY"
    ;;
  "pr create") exit 0 ;;
  "api repos/uscient/agent-lab/commits/"*)
    printf '%s\n' "$WORKSTREAM_BASE_CHECKS_JSON"
    ;;
  "api repos/uscient/agent-lab/compare/"*)
    printf '%s\n' "${WORKSTREAM_COMPARE_STATUS:-ahead}"
    ;;
  "api repos/uscient/agent-lab/pulls/17/merge")
    merge_result="${WORKSTREAM_MERGE_RESULT:-}"
    if [ -z "$merge_result" ]; then
      merge_result='{"merged":true,"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
    fi
    printf '%s\n' "$merge_result"
    if printf '%s' "$merge_result" | /usr/bin/jq -e '.merged == true' >/dev/null; then
      : > "$WORKSTREAM_MERGED_MARKER"
    fi
    ;;
  *) exit 99 ;;
esac
EOF
chmod +x "$fake_bin/gh"

base_oid='1111111111111111111111111111111111111111'
head_oid='0123456789abcdef0123456789abcdef01234567'
valid_body="$work/valid-body.md"
cat > "$valid_body" <<'EOF'
## Summary

Integrate a verified fixture.

## Motivation / Context

The merge helper requires exact current evidence.

## Changes

- exercise merge evidence.

## Testing

- `bash tests/dev/workstream-cases.sh` — pass.

## Evidence

### Cycle 1

- Route: `slice/demo/format` -> `work/demo`
- Base: `1111111111111111111111111111111111111111`
- Head: `0123456789abcdef0123456789abcdef01234567`
- Scenarios: `WF-CI-CURRENT`
- Assertions: `WORKSTREAM-EVIDENCE-CURRENT`
- RED predecessor: `1111111111111111111111111111111111111111`
- RED: `bash tests/dev/workstream-cases.sh` — rc=1 classification=assertion-failure
- GREEN: `bash tests/dev/workstream-cases.sh` — rc=0 classification=success
- Product mutation: `reject-stale-evidence` — detected rc=1 classification=assertion-failure
- CI mutation: `bypass-evidence` — detected rc=1 classification=assertion-failure
- Runner: local Bash fixture
- Duration: 1s
- Cleanup: temporary fixture removed
- Artifacts: N/A — no retained binary artifacts
- Unverified: none
EOF
valid_json="$(jq -cn --rawfile body "$valid_body" '{
  number:17,state:"OPEN",isDraft:false,baseRefName:"work/demo",
  baseRefOid:"1111111111111111111111111111111111111111",
  headRefName:"slice/demo/format",
  headRefOid:"0123456789abcdef0123456789abcdef01234567",
  isCrossRepository:false,headRepository:{nameWithOwner:"uscient/agent-lab"},
  mergeStateStatus:"CLEAN",reviewDecision:"APPROVED",body:$body,
  statusCheckRollup:[
    {name:"Fast",workflowName:"CI",status:"COMPLETED",conclusion:"SUCCESS"},
    {name:"Required gates",workflowName:"CI",status:"COMPLETED",conclusion:"SUCCESS"},
    {name:"CodeQL",workflowName:"CodeQL",status:"COMPLETED",conclusion:"SUCCESS"},
    {name:"CodeQL",workflowName:"",status:"COMPLETED",conclusion:"SUCCESS"}
  ]
}')"
valid_base_checks='{"check_runs":[{"name":"Required gates","app":{"slug":"github-actions"},"status":"completed","conclusion":"success"},{"name":"CodeQL","app":{"slug":"github-actions"},"status":"completed","conclusion":"success"},{"name":"CodeQL","app":{"slug":"github-code-scanning"},"status":"completed","conclusion":"success"}]}'

route_fixture="$work/route"
mkdir -p "$route_fixture/scripts/dev"
sed "s#/usr/bin/gh#$fake_bin/gh#" "$command_path" > "$route_fixture/scripts/dev/workstream"
cp "$repo_root/scripts/dev/workflow-check" "$route_fixture/scripts/dev/workflow-check"
chmod +x "$route_fixture/scripts/dev/workstream"
chmod +x "$route_fixture/scripts/dev/workflow-check"
git -C "$route_fixture" init -q
git -C "$route_fixture" add scripts/dev/workstream scripts/dev/workflow-check
git -C "$route_fixture" -c user.name=test -c user.email=test@example.invalid \
  commit -qm fixture
fixture_oid="$(git -C "$route_fixture" rev-parse HEAD)"
printf 'scripts/dev/workstream-*\n' > "$route_fixture/.git/info/exclude"
git -C "$route_fixture" update-ref refs/heads/slice/demo/format "$fixture_oid"
git -C "$route_fixture" symbolic-ref HEAD refs/heads/slice/demo/format
: > "$gh_log"
if PATH="$fake_bin:/usr/bin:/bin" WORKSTREAM_GH_LOG="$gh_log" \
  WORKSTREAM_MERGED_MARKER="$merged_marker" \
  "$route_fixture/scripts/dev/workstream" pr --title format --body body >/dev/null \
  && grep -Fxq 'pr create --repo github.com/uscient/agent-lab --base work/demo --head slice/demo/format --title format --body body' "$gh_log"; then
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
git -C "$route_fixture" symbolic-ref HEAD refs/heads/slice/group/g0-operator-surface/format
: > "$gh_log"
if PATH="$fake_bin:/usr/bin:/bin" WORKSTREAM_GH_LOG="$gh_log" \
  WORKSTREAM_MERGED_MARKER="$merged_marker" \
  "$route_fixture/scripts/dev/workstream" pr --title format --body body >/dev/null \
  && grep -Fxq 'pr create --repo github.com/uscient/agent-lab --base group/g0-operator-surface --head slice/group/g0-operator-surface/format --title format --body body' "$gh_log"; then
  pass "group slice PR routing derives the matching group base"
else
  fail "group slice PR routing derives the matching group base"
fi
git -C "$route_fixture" symbolic-ref HEAD refs/heads/group/g0-operator-surface
: > "$gh_log"
if PATH="$fake_bin:/usr/bin:/bin" WORKSTREAM_GH_LOG="$gh_log" \
  WORKSTREAM_MERGED_MARKER="$merged_marker" \
  "$route_fixture/scripts/dev/workstream" group-pr --title complete --body body >/dev/null \
  && grep -Fxq 'pr create --repo github.com/uscient/agent-lab --base flow --head group/g0-operator-surface --draft --title complete --body body' "$gh_log"; then
  pass "group PR routing is fixed to flow and remains draft"
else
  fail "group PR routing is fixed to flow and remains draft"
fi
git -C "$route_fixture" symbolic-ref HEAD \
  refs/heads/group/g0-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
if PATH="$fake_bin:/usr/bin:/bin" WORKSTREAM_GH_LOG="$gh_log" \
  "$route_fixture/scripts/dev/workstream" group-pr --title bad --body body >/dev/null 2>&1; then
  fail "overlong group cannot enter the integration route"
else
  pass "overlong group cannot enter the integration route"
fi
git -C "$route_fixture" symbolic-ref HEAD refs/heads/work/demo
: > "$gh_log"
if PATH="$fake_bin:/usr/bin:/bin" WORKSTREAM_GH_LOG="$gh_log" \
  WORKSTREAM_MERGED_MARKER="$merged_marker" \
  "$route_fixture/scripts/dev/workstream" final --title complete --body body >/dev/null \
  && grep -Fxq 'pr create --repo github.com/uscient/agent-lab --base dev --head work/demo --draft --title complete --body body' "$gh_log"; then
  pass "final PR routing is fixed to dev and remains draft"
else
  fail "final PR routing is fixed to dev and remains draft"
fi
hostile_bin="$work/hostile-bin"
hostile_marker="$work/hostile-gh-ran"
mkdir -p "$hostile_bin"
printf '%s\n' '#!/usr/bin/env bash' ': > "$WORKSTREAM_HOSTILE_MARKER"' 'exit 97' \
  > "$hostile_bin/gh"
chmod +x "$hostile_bin/gh"
printf '%s\n' '#!/usr/bin/env bash' ': > "$WORKSTREAM_HOSTILE_MARKER"' 'exit 97' \
  > "$hostile_bin/awk"
chmod +x "$hostile_bin/awk"
: > "$gh_log"
if PATH="$hostile_bin:$fake_bin:/usr/bin:/bin" WORKSTREAM_GH_LOG="$gh_log" \
  WORKSTREAM_HOSTILE_MARKER="$hostile_marker" \
  "$route_fixture/scripts/dev/workstream" final --title trusted --body body >/dev/null \
  && [ ! -e "$hostile_marker" ] \
  && grep -Fxq 'pr create --repo github.com/uscient/agent-lab --base dev --head work/demo --draft --title trusted --body body' "$gh_log"; then
  pass "trusted GitHub client path defeats PATH injection"
else
  fail "trusted GitHub client path defeats PATH injection"
fi
: > "$gh_log"
if GH_REPO=attacker/other GH_HOST=example.invalid \
  PATH="$fake_bin:/usr/bin:/bin" WORKSTREAM_GH_LOG="$gh_log" \
  "$route_fixture/scripts/dev/workstream" final --title pinned --body body >/dev/null \
  && grep -Fxq 'pr create --repo github.com/uscient/agent-lab --base dev --head work/demo --draft --title pinned --body body' "$gh_log"; then
  pass "ambient GitHub repository and host cannot redirect writes"
else
  fail "ambient GitHub repository and host cannot redirect writes"
fi

sync_origin="$work/sync-origin.git"
sync_fixture="$work/sync-fixture"
sync_producer="$work/sync-producer"
sync_trace="$work/sync.trace"
git init --bare -q "$sync_origin" || infra "cannot create sync origin"
mkdir -p "$sync_fixture/scripts/dev"
sed "s#/usr/bin/gh#$fake_bin/gh#" "$command_path" > "$sync_fixture/scripts/dev/workstream"
cp "$repo_root/scripts/dev/workflow-check" "$sync_fixture/scripts/dev/workflow-check"
chmod +x "$sync_fixture/scripts/dev/workstream"
chmod +x "$sync_fixture/scripts/dev/workflow-check"
git -C "$sync_fixture" init -q || infra "cannot create sync fixture"
git -C "$sync_fixture" add scripts/dev/workstream scripts/dev/workflow-check
git -C "$sync_fixture" -c user.name=test -c user.email=test@example.invalid \
  commit -qm base || infra "cannot commit sync fixture"
git -C "$sync_fixture" branch flow
git -C "$sync_fixture" branch group/g0-operator-surface
git -C "$sync_fixture" remote add origin "$sync_origin"
git -C "$sync_fixture" push -q origin flow group/g0-operator-surface \
  || infra "cannot seed sync origin"
git -C "$sync_fixture" switch -q group/g0-operator-surface
git clone -q --branch group/g0-operator-surface "$sync_origin" "$sync_producer" \
  || infra "cannot clone sync producer"
git -C "$sync_producer" switch -q -c slice/group/g0-operator-surface/accepted
git -C "$sync_producer" -c user.name=test -c user.email=test@example.invalid \
  commit --allow-empty -qm slice || infra "cannot commit sync slice"
git -C "$sync_producer" switch -q group/g0-operator-surface
git -C "$sync_producer" -c user.name=test -c user.email=test@example.invalid \
  merge --no-ff -qm 'Merge accepted slice' slice/group/g0-operator-surface/accepted \
  || infra "cannot create accepted merge fixture"
accepted_oid="$(git -C "$sync_producer" rev-parse HEAD)"
git -C "$sync_producer" push -q origin group/g0-operator-surface \
  || infra "cannot publish accepted merge fixture"
if GIT_TRACE="$sync_trace" PATH="$hostile_bin:$fake_bin:/usr/bin:/bin" \
  "$sync_fixture/scripts/dev/workstream" sync >/dev/null 2>&1 \
  && [ "$(git -C "$sync_fixture" rev-parse HEAD)" = "$accepted_oid" ] \
  && grep -Fq 'merge --ff-only origin/group/g0-operator-surface' "$sync_trace" \
  && grep -Fq 'merge --no-ff --no-edit origin/flow' "$sync_trace" \
  && ! grep -Fq 'rebase origin/flow' "$sync_trace"; then
  pass "sync recovers accepted remote merges before preserving parent ancestry"
else
  fail "sync recovers accepted remote merges before preserving parent ancestry"
fi
git -C "$route_fixture" symbolic-ref HEAD refs/heads/flow
: > "$gh_log"
if PATH="$fake_bin:/usr/bin:/bin" WORKSTREAM_GH_LOG="$gh_log" \
  WORKSTREAM_MERGED_MARKER="$merged_marker" \
  "$route_fixture/scripts/dev/workstream" final --title complete --body body >/dev/null \
  && grep -Fxq 'pr create --repo github.com/uscient/agent-lab --base dev --head flow --draft --title complete --body body' "$gh_log"; then
  pass "program final PR routing is fixed from flow to dev and remains draft"
else
  fail "program final PR routing is fixed from flow to dev and remains draft"
fi

run_merge() {
  local json="$1" candidate="${2:-$route_fixture/scripts/dev/workstream}" \
    comparison="${3:-ahead}" base_checks="${4:-$valid_base_checks}" rc=0 base \
    merge_result="${5:-}" \
    merge_path="${WORKSTREAM_CASE_PATH:-$fake_bin:/usr/bin:/bin}"
  if [ -z "$merge_result" ]; then
    merge_result='{"merged":true,"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
  fi
  : > "$gh_log"
  find "$merged_marker" -maxdepth 0 -delete >/dev/null 2>&1 || true
  base="$(printf '%s' "$json" | jq -r .baseRefName)"
  git -C "$route_fixture" update-ref "refs/heads/$base" "$fixture_oid"
  git -C "$route_fixture" symbolic-ref HEAD "refs/heads/$base"
  PATH="$merge_path" WORKSTREAM_GH_LOG="$gh_log" WORKSTREAM_PR_JSON="$json" \
    WORKSTREAM_MERGED_MARKER="$merged_marker" WORKSTREAM_COMPARE_STATUS="$comparison" \
    WORKSTREAM_BASE_CHECKS_JSON="$base_checks" WORKSTREAM_MERGE_RESULT="$merge_result" \
    "$candidate" merge 17 >"$work/stdout" 2>"$work/stderr" || rc=$?
  return "$rc"
}

updated_body_marker="$work/updated-body"
run_evidence() {
  local json="$1" body="$2" candidate="${3:-$route_fixture/scripts/dev/workstream}" rc=0
  : > "$gh_log"
  find "$updated_body_marker" -maxdepth 0 -delete >/dev/null 2>&1 || true
  git -C "$route_fixture" symbolic-ref HEAD refs/heads/slice/demo/format
  PATH="$fake_bin:/usr/bin:/bin" WORKSTREAM_GH_LOG="$gh_log" WORKSTREAM_PR_JSON="$json" \
    WORKSTREAM_MERGED_MARKER="$merged_marker" WORKSTREAM_UPDATED_BODY="$updated_body_marker" \
    "$candidate" evidence 17 "$body" >"$work/stdout" 2>"$work/stderr" || rc=$?
  return "$rc"
}

appended_body="$work/appended-body.md"
{
  cat "$valid_body"
  sed -n '/^### Cycle 1$/,$p' "$valid_body" | sed 's/^### Cycle 1$/### Cycle 2/'
} > "$appended_body"
if run_evidence "$valid_json" "$appended_body" \
  && cmp -s "$appended_body" "$updated_body_marker" \
  && grep -Fxq "pr edit 17 --repo github.com/uscient/agent-lab --body-file $appended_body" "$gh_log"; then
  pass "bounded evidence update appends a validated current cycle"
else
  fail "bounded evidence update appends a validated current cycle"
fi

rewritten_body="$work/rewritten-body.md"
sed '0,/WORKSTREAM-EVIDENCE-CURRENT/s//WORKSTREAM-EVIDENCE-FORGED/' \
  "$appended_body" > "$rewritten_body"
if run_evidence "$valid_json" "$rewritten_body"; then
  fail "bounded evidence update preserves every prior cycle"
elif ! grep -q '^pr edit ' "$gh_log"; then
  pass "bounded evidence update preserves every prior cycle"
else
  fail "bounded evidence update preserves every prior cycle"
fi

append_mutant="$route_fixture/scripts/dev/workstream-append-mutant"
sed 's#PATH=/usr/bin:/bin "$real_bash" "$workflow_check" evidence-append "$old_body" "$body_file" >/dev/null#true#' \
  "$route_fixture/scripts/dev/workstream" > "$append_mutant"
chmod +x "$append_mutant"
if [ "$(cmp -s "$route_fixture/scripts/dev/workstream" "$append_mutant"; printf '%s' "$?")" -ne 0 ] \
  && run_evidence "$valid_json" "$rewritten_body" "$append_mutant"; then
  pass "append-only evidence sensitivity mutation turns RED"
else
  fail "append-only evidence sensitivity mutation turns RED"
fi

if run_merge "$valid_json" \
  && grep -Fxq "api repos/uscient/agent-lab/compare/$base_oid...$head_oid --hostname github.com --jq .status" "$gh_log" \
  && grep -Fxq "api repos/uscient/agent-lab/pulls/17/merge --hostname github.com --method PUT -f merge_method=merge -f sha=$head_oid" "$gh_log" \
  && ! grep -Eq -- 'merge_method=(squash|rebase)|delete-branch' "$gh_log"; then
  pass "green matching slice PR is merged with its observed head commit"
else
  fail "green matching slice PR is merged with its observed head commit"
fi

find "$hostile_marker" -maxdepth 0 -delete >/dev/null 2>&1 || true
if WORKSTREAM_CASE_PATH="$hostile_bin:$fake_bin:/usr/bin:/bin" run_merge "$valid_json" \
  && [ ! -e "$hostile_marker" ]; then
  pass "merge evidence validation defeats ambient parser PATH injection"
else
  fail "merge evidence validation defeats ambient parser PATH injection"
fi

queued_result='{"merged":false,"message":"merge queue required"}'
if run_merge "$valid_json" "$route_fixture/scripts/dev/workstream" ahead \
  "$valid_base_checks" "$queued_result"; then
  fail "intermediate integration never leaves a queued merge live"
elif [ ! -e "$merged_marker" ] && grep -q 'merge queues are not an intermediate route' "$work/stderr"; then
  pass "intermediate integration never leaves a queued merge live"
else
  fail "intermediate integration never leaves a queued merge live"
fi

stale_evidence_json="$(printf '%s' "$valid_json" | jq -c \
  '.body |= sub("0123456789abcdef0123456789abcdef01234567"; "3333333333333333333333333333333333333333")')"
if run_merge "$stale_evidence_json"; then
  fail "stale PR-body evidence blocks integration"
elif ! grep -q '^api repos/uscient/agent-lab/pulls/17/merge ' "$gh_log"; then
  pass "stale PR-body evidence blocks integration"
else
  fail "stale PR-body evidence blocks integration"
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
    changes-requested) mutated="${valid_json/\"reviewDecision\":\"APPROVED\"/$replacement}" ;;
    dirty) mutated="${valid_json/\"mergeStateStatus\":\"CLEAN\"/$replacement}" ;;
    pending) mutated="${valid_json/\"status\":\"COMPLETED\"/$replacement}" ;;
    failed) mutated="${valid_json/\"conclusion\":\"SUCCESS\"/$replacement}" ;;
    skipped) mutated="${valid_json/\"conclusion\":\"SUCCESS\"/$replacement}" ;;
  esac
  if run_merge "$mutated"; then
    fail "$name PR state blocks integration"
  elif ! grep -q '^api repos/uscient/agent-lab/pulls/17/merge ' "$gh_log"; then
    pass "$name PR state blocks integration"
  else
    fail "$name PR state blocks integration"
  fi
done

group_json="$(printf '%s' "$valid_json" | jq -c \
  '.baseRefName="group/g0-operator-surface" |
   .headRefName="slice/group/g0-operator-surface/format" |
   .body |= sub("`slice/demo/format` -> `work/demo`";
                "`slice/group/g0-operator-surface/format` -> `group/g0-operator-surface`")')"
if run_merge "$group_json"; then
  pass "approved current-base group slice integrates through the helper"
else
  fail "approved current-base group slice integrates through the helper"
fi

wrong_route_json="$(printf '%s' "$valid_json" | jq -c \
  '.baseRefName="group/g0-operator-surface" |
   .headRefName="slice/group/g0-operator-surface/format"')"
if run_merge "$wrong_route_json"; then
  fail "PR body route must match hosted metadata"
elif ! grep -q '^api repos/uscient/agent-lab/pulls/17/merge ' "$gh_log"; then
  pass "PR body route must match hosted metadata"
else
  fail "PR body route must match hosted metadata"
fi

flow_json="$(printf '%s' "$valid_json" | jq -c \
  '.baseRefName="flow" | .headRefName="group/g0-operator-surface" |
   .body |= sub("`slice/demo/format` -> `work/demo`";
                "`group/g0-operator-surface` -> `flow`")')"
if run_merge "$flow_json"; then
  pass "approved current-base group PR integrates into flow through the helper"
else
  fail "approved current-base group PR integrates into flow through the helper"
fi

missing_base_codeql='{"check_runs":[{"name":"Required gates","app":{"slug":"github-actions"},"status":"completed","conclusion":"success"},{"name":"CodeQL","app":{"slug":"github-code-scanning"},"status":"completed","conclusion":"success"}]}'
if run_merge "$flow_json" "$route_fixture/scripts/dev/workstream" ahead "$missing_base_codeql"; then
  fail "group integration waits for a green CodeQL result on the flow base"
elif ! grep -q '^api repos/uscient/agent-lab/pulls/17/merge ' "$gh_log"; then
  pass "group integration waits for a green CodeQL result on the flow base"
else
  fail "group integration waits for a green CodeQL result on the flow base"
fi

for json_case in \
  "wrong-number|$(printf '%s' "$valid_json" | jq -c '.number=18')" \
  "unapproved|$(printf '%s' "$valid_json" | jq -c '.reviewDecision=""')" \
  "cross-repository|$(printf '%s' "$valid_json" | jq -c '.isCrossRepository=true')" \
  "foreign-repository|$(printf '%s' "$valid_json" | jq -c '.headRepository.nameWithOwner="other/repo"')" \
  "invalid-base-oid|$(printf '%s' "$valid_json" | jq -c '.baseRefOid="bad"')" \
  "duplicate-check|$(printf '%s' "$valid_json" | jq -c '.statusCheckRollup += [.statusCheckRollup[0]]')"; do
  name="${json_case%%|*}"
  mutated="${json_case#*|}"
  if run_merge "$mutated"; then
    fail "$name metadata blocks integration"
  elif ! grep -q '^api repos/uscient/agent-lab/pulls/17/merge ' "$gh_log"; then
    pass "$name metadata blocks integration"
  else
    fail "$name metadata blocks integration"
  fi
done

if run_merge "$valid_json" "$route_fixture/scripts/dev/workstream" diverged; then
  fail "head that does not contain the observed base blocks integration"
elif ! grep -q '^api repos/uscient/agent-lab/pulls/17/merge ' "$gh_log"; then
  pass "head that does not contain the observed base blocks integration"
else
  fail "head that does not contain the observed base blocks integration"
fi

empty_checks="$(printf '%s' "$valid_json" | jq -c '.statusCheckRollup = []')"
if run_merge "$empty_checks"; then
  fail "missing checks block integration"
elif ! grep -q '^api repos/uscient/agent-lab/pulls/17/merge ' "$gh_log"; then
  pass "missing checks block integration"
else
  fail "missing checks block integration"
fi

missing_codeql="$(printf '%s' "$valid_json" | jq -c \
  '.statusCheckRollup |= map(select(.name != "CodeQL" or .workflowName != "CodeQL"))')"
if run_merge "$missing_codeql"; then
  fail "missing CodeQL PR result blocks integration"
elif ! grep -q '^api repos/uscient/agent-lab/pulls/17/merge ' "$gh_log"; then
  pass "missing CodeQL PR result blocks integration"
else
  fail "missing CodeQL PR result blocks integration"
fi

mutant="$route_fixture/scripts/dev/workstream-mutant"
sed 's/(all(\.statusCheckRollup\[\]; \.status == "COMPLETED" and \.conclusion == "SUCCESS"))/(true)/' \
  "$route_fixture/scripts/dev/workstream" > "$mutant"
chmod +x "$mutant"
if [ "$(cmp -s "$command_path" "$mutant"; printf '%s' "$?")" -ne 0 ] \
  && run_merge "${valid_json/\"conclusion\":\"SUCCESS\"/\"conclusion\":\"FAILURE\"}" "$mutant"; then
  pass "all-checks sensitivity mutation turns RED"
else
  fail "all-checks sensitivity mutation turns RED"
fi

evidence_mutant="$route_fixture/scripts/dev/workstream-evidence-mutant"
sed 's#PATH=/usr/bin:/bin "$real_bash" "$workflow_check" pr-body-strict "$evidence_file" "$base_sha" "$head_sha" "$head_ref" "$base_ref" >/dev/null#true#' \
  "$route_fixture/scripts/dev/workstream" > "$evidence_mutant"
chmod +x "$evidence_mutant"
if [ "$(cmp -s "$route_fixture/scripts/dev/workstream" "$evidence_mutant"; printf '%s' "$?")" -ne 0 ] \
  && run_merge "$stale_evidence_json" "$evidence_mutant"; then
  pass "evidence-validation sensitivity mutation turns RED"
else
  fail "evidence-validation sensitivity mutation turns RED"
fi

squash_mutant="$route_fixture/scripts/dev/workstream-squash-mutant"
sed 's/merge_method=merge/merge_method=squash/' \
  "$route_fixture/scripts/dev/workstream" > "$squash_mutant"
chmod +x "$squash_mutant"
if [ "$(cmp -s "$route_fixture/scripts/dev/workstream" "$squash_mutant"; printf '%s' "$?")" -ne 0 ] \
  && run_merge "$valid_json" "$squash_mutant" \
  && grep -Fq 'api repos/uscient/agent-lab/pulls/17/merge --hostname github.com --method PUT -f merge_method=squash' "$gh_log"; then
  pass "merge-method sensitivity mutation is observable and turns the exact-command oracle RED"
else
  fail "merge-method sensitivity mutation is observable and turns the exact-command oracle RED"
fi

printf 'SUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
