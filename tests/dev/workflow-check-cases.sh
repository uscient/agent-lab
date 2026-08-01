#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
checker="${AGENT_LAB_WORKFLOW_CHECK:-$repo_root/scripts/dev/workflow-check}"
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1
work="$(mktemp -d)" || {
  printf 'INFRA workflow-check contract cannot create temporary state\n' >&2
  exit 125
}
cleanup() { find "$work" -depth -delete >/dev/null 2>&1 || true; }
trap cleanup EXIT

passes=0
failures=0
pass() { printf 'PASS %s\n' "$1"; passes=$((passes + 1)); }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

run_checker() {
  checker_rc=0
  checker_out="$("$checker" "$@" 2>&1)" || checker_rc=$?
}

expect_ok() {
  local name="$1"
  shift
  run_checker "$@"
  if [ "$checker_rc" -eq 0 ]; then
    pass "$name"
  else
    fail "$name (rc=$checker_rc)"
    printf '%s\n' "$checker_out"
  fi
}

expect_reject() {
  local name="$1" expected="$2"
  shift 2
  run_checker "$@"
  if [ "$checker_rc" -eq 1 ] && printf '%s\n' "$checker_out" | grep -Fq "$expected"; then
    pass "$name"
  else
    fail "$name (rc=$checker_rc; expected: $expected)"
    printf '%s\n' "$checker_out"
  fi
}

expect_infra() {
  local name="$1" expected="$2"
  shift 2
  run_checker "$@"
  if [ "$checker_rc" -eq 125 ] && printf '%s\n' "$checker_out" | grep -Fq "$expected"; then
    pass "$name"
  else
    fail "$name (rc=$checker_rc; expected infrastructure: $expected)"
    printf '%s\n' "$checker_out"
  fi
}

expect_usage() {
  local name="$1"
  shift
  run_checker "$@"
  if [ "$checker_rc" -eq 2 ] && printf '%s\n' "$checker_out" | grep -Fq "usage:"; then
    pass "$name"
  else
    fail "$name (rc=$checker_rc; expected usage failure)"
    printf '%s\n' "$checker_out"
  fi
}

if [ ! -x "$checker" ]; then
  fail "workflow checker exists and is executable"
  printf 'SUMMARY pass=%s fail=%s\n' "$passes" "$failures"
  exit 1
fi

echo "== command contract =="
expect_usage "missing command fails closed"
expect_usage "unknown command fails closed" unknown
expect_usage "missing commit subject fails closed" commit
expect_usage "missing PR body path fails closed" pr-body
expect_usage "missing PR base fails closed" pr-base
expect_usage "branch rejects extra arguments" branch xor/dev-lane extra
expect_usage "commit rejects extra arguments" commit "Implement workflow checks" extra
expect_usage "commits rejects extra arguments" commits origin/dev extra
expect_usage "PR title rejects extra arguments" pr-title "Implement workflow checks" extra
expect_usage "PR body rejects extra arguments" pr-body body.md extra
expect_usage "PR base rejects extra arguments" pr-base dev extra
expect_usage "all rejects extra arguments" all origin/dev extra

echo "== commit subjects =="
expect_ok "plain imperative subject is accepted" \
  commit "Fix doctor secret scan false positives"
expect_ok "scoped conventional subject is accepted" \
  commit "fix(ci): reject branch-derived PR titles"
expect_ok "test-first subject is accepted" \
  commit "test(dev): define workflow metadata contract"
expect_reject "short subject is rejected" "12 to 72" commit "Fix it"
expect_reject "long subject is rejected" "12 to 72" commit \
  "Document a deliberately overlong workflow subject that exceeds the accepted limit now"
expect_reject "multiline subject is rejected" "one printable line" commit $'Fix workflow\nsecond line'
expect_reject "trailing period is rejected" "trailing period" commit \
  "Fix workflow metadata checks."
expect_reject "WIP subject is rejected" "unfinished" commit \
  "WIP define workflow checks"
expect_reject "merge boilerplate is rejected" "merge boilerplate" commit \
  "Merge pull request #20 from uscient/dev"
expect_reject "generic update subject is rejected" "generic" commit \
  "Update: miscellaneous changes"
expect_reject "ref-like subject is rejected" "branch-derived" commit \
  "xor/dev-lane"

echo "== branch names =="
expect_ok "operator lane is accepted" branch "xor/dev-lane"
expect_ok "numeric topic is accepted" branch "fix/9"
expect_ok "agent timestamp branch is accepted" branch "agent/codex/20260731-120000"
expect_ok "bootstrap-compatible agent slug is accepted" branch "agent/codex/work_item.v1"
expect_ok "Claude bootstrap branch is accepted" branch "agent/claude/task_slug.v1"
expect_ok "Grok bootstrap branch is accepted" branch "agent/grok/task_slug.v1"
expect_ok "test bootstrap branch is accepted" branch "agent/test/task_slug.v1"
expect_ok "existing work-now branch remains policy-valid" branch work/now
expect_ok "uppercase work branch remains policy-valid" branch Xor/Dev-Lane
expect_ok "manual underscore branch remains policy-valid" branch xor/dev_lane
expect_reject "protected dev is rejected" "protected" branch dev
expect_reject "protected master is rejected" "protected" branch master
expect_reject "protected main is rejected" "protected" branch main
expect_reject "empty branch is rejected" "detached or empty" branch ""
expect_reject "invalid Git ref is rejected" "invalid Git branch" branch "bad branch"

echo "== pull request metadata =="
expect_ok "outcome PR title is accepted" pr-title \
  "Standardize development workflow metadata"
expect_ok "conventional PR title is accepted" pr-title \
  "chore(dev): coordinate shared work"
expect_reject "Dev PR title is rejected" "generic" pr-title Dev
expect_reject "branch-derived Fix/9 title is rejected" "branch-derived" pr-title Fix/9
expect_reject "agent branch title is rejected" "branch-derived" pr-title \
  Agent/codex/20260731-120000
expect_reject "draft marker is rejected" "unfinished" pr-title \
  "[WIP] Standardize development workflow"
expect_reject "long PR title is rejected" "12 to 72" pr-title \
  "Document a deliberately overlong workflow title that exceeds the accepted limit now"
expect_reject "multiline PR title is rejected" "one printable line" pr-title \
  $'Standardize development workflow\nsecond line'
expect_reject "PR title trailing period is rejected" "trailing period" pr-title \
  "Standardize development workflow."
expect_reject "merge boilerplate PR title is rejected" "merge boilerplate" pr-title \
  "Merge pull request #20 from uscient/dev"
expect_ok "dev PR base is accepted" pr-base dev
expect_reject "master PR base is rejected" "PR base must be dev" pr-base master
expect_reject "main PR base is rejected" "PR base must be dev" pr-base main
expect_reject "arbitrary PR base is rejected" "PR base must be dev" pr-base release

good_body="$work/good-body.md"
cat > "$good_body" <<'EOF'
## Summary

Add deterministic development-workflow checks.

## Motivation / Context

Generic pull-request metadata hides the delivered outcome and evidence.

## Changes

- validate commit and pull-request metadata;
- preserve the existing policy boundary.

## Testing

- `bash tests/dev/workflow-check-cases.sh` — pass.
EOF
expect_ok "complete PR body is accepted" pr-body "$good_body"

empty_body="$work/empty-body.md"
cat > "$empty_body" <<'EOF'
## Summary

<!-- One line summary of the change -->

## Motivation / Context

Why this matters.

## Changes

One change.

## Testing

Not run — fixture.
EOF
expect_reject "placeholder comment is rejected" "placeholder" pr-body "$empty_body"

notice_body="$work/notice-body.md"
{
  printf '%s\n' '> **⚠️ Important policy notice**'
  cat "$good_body"
} > "$notice_body"
expect_reject "member notice is rejected" "member notice" pr-body "$notice_body"

for section in "Summary" "Motivation / Context" "Changes" "Testing"; do
  section_slug="$(printf '%s' "$section" | tr ' /' '--')"
  missing_body="$work/missing-$section_slug.md"
  awk -v heading="## $section" '
    $0 == heading { skip = 1; next }
    /^## / && skip { skip = 0 }
    !skip { print }
  ' "$good_body" > "$missing_body"
  expect_reject "missing $section section is rejected" "missing section: $section" \
    pr-body "$missing_body"

  empty_section_body="$work/empty-$section_slug.md"
  awk -v heading="## $section" '
    $0 == heading { print; skip = 1; next }
    /^## / && skip { skip = 0 }
    !skip { print }
  ' "$good_body" > "$empty_section_body"
  expect_reject "empty $section section is rejected" "empty section: $section" \
    pr-body "$empty_section_body"
done

reordered_body="$work/reordered-body.md"
cat > "$reordered_body" <<'EOF'
## Motivation / Context

Why this matters.

## Summary

One summary.

## Changes

One change.

## Testing

Not run — fixture.
EOF
expect_reject "required sections out of order are rejected" "section order" \
  pr-body "$reordered_body"

duplicate_body="$work/duplicate-body.md"
{
  cat "$good_body"
  printf '%s\n' '## Summary' 'Duplicate summary.'
} > "$duplicate_body"
expect_reject "duplicate required section is rejected" "duplicate section: Summary" \
  pr-body "$duplicate_body"

fenced_body="$work/fenced-body.md"
{
  cat "$good_body"
  printf '%s\n' '```markdown' '## Summary' 'Not a real section.' '```'
} > "$fenced_body"
expect_ok "heading inside a fenced block is ignored" pr-body "$fenced_body"

commented_body="$work/commented-body.md"
{
  cat "$good_body"
  printf '%s\n' '<!--' '## Summary' 'Not a real section.' '-->'
} > "$commented_body"
expect_ok "heading inside an HTML comment is ignored" pr-body "$commented_body"

not_run_body="$work/not-run-body.md"
cat > "$not_run_body" <<'EOF'
## Summary

Add deterministic development-workflow checks.

## Motivation / Context

Generic pull-request metadata hides the delivered outcome and evidence.

## Changes

- validate pull-request metadata.

## Testing

Not run — documentation-only fixture.
EOF
expect_ok "explicit not-run reason is accepted" pr-body "$not_run_body"

vague_testing_body="$work/vague-testing-body.md"
cat > "$vague_testing_body" <<'EOF'
## Summary

Add deterministic development-workflow checks.

## Motivation / Context

Generic pull-request metadata hides the delivered outcome and evidence.

## Changes

- validate pull-request metadata.

## Testing

Tests pass.
EOF
expect_reject "vague Testing evidence is rejected" "Testing must list" \
  pr-body "$vague_testing_body"

unchecked_body="$work/unchecked-body.md"
{
  cat "$good_body"
  printf '%s\n' '- [ ] placeholder checklist item'
} > "$unchecked_body"
expect_reject "unchecked placeholder is rejected" "unchecked placeholder" \
  pr-body "$unchecked_body"
expect_infra "missing body file is infrastructure" "cannot read PR body" \
  pr-body "$work/absent.md"

make_repo() {
  local path="$1" author_name="${2:-xormania}" \
    author_email="${3:-127287135+xormania@users.noreply.github.com}"
  mkdir -p "$path"
  git -C "$path" init -q
  git -C "$path" config core.hooksPath "$work/no-hooks"
  git -C "$path" config commit.gpgsign false
  git -C "$path" config tag.gpgsign false
  git -C "$path" config user.name "$author_name"
  git -C "$path" config user.email "$author_email"
  printf 'base\n' > "$path/file.txt"
  git -C "$path" add file.txt
  git -C "$path" commit -qm "Create fixture baseline"
  git -C "$path" branch -M dev
  git -C "$path" update-ref refs/remotes/origin/dev HEAD
  git -C "$path" switch -qc xor/workflow
}

set_author() {
  local path="$1" name="$2" email="$3"
  git -C "$path" config user.name "$name"
  git -C "$path" config user.email "$email"
}

commit_file() {
  local path="$1" message="$2"
  printf '%s\n' "$message" >> "$path/file.txt"
  git -C "$path" add file.txt
  git -C "$path" commit -qm "$message"
}

run_in_repo() {
  local path="$1"
  shift
  checker_rc=0
  checker_out="$(cd "$path" && "$checker" "$@" 2>&1)" || checker_rc=$?
}

echo "== introduced commits =="
mkdir -p "$work/no-hooks"
valid_repo="$work/valid-repo"
make_repo "$valid_repo"
commit_file "$valid_repo" "test(dev): define workflow metadata contract"
commit_file "$valid_repo" "Implement workflow metadata checks"
run_in_repo "$valid_repo" commits origin/dev
if [ "$checker_rc" -eq 0 ] && printf '%s\n' "$checker_out" | grep -Fq "commits=2"; then
  pass "valid introduced commits are accepted"
else
  fail "valid introduced commits are accepted (rc=$checker_rc)"
  printf '%s\n' "$checker_out"
fi

before_status="$(git -C "$valid_repo" status --porcelain=v1)"
run_in_repo "$valid_repo" all origin/dev
after_status="$(git -C "$valid_repo" status --porcelain=v1)"
if [ "$checker_rc" -eq 0 ] && [ "$before_status" = "$after_status" ]; then
  pass "all check validates branch and commits without changing Git state"
else
  fail "all check validates branch and commits without changing Git state (rc=$checker_rc)"
  printf '%s\n' "$checker_out"
fi

git -C "$valid_repo" switch --detach -q
run_in_repo "$valid_repo" branch
if [ "$checker_rc" -eq 1 ] && printf '%s\n' "$checker_out" | grep -Fq "detached or empty"; then
  pass "detached checkout is rejected"
else
  fail "detached checkout is rejected (rc=$checker_rc)"
  printf '%s\n' "$checker_out"
fi
git -C "$valid_repo" switch -q xor/workflow

bad_subject_repo="$work/bad-subject-repo"
make_repo "$bad_subject_repo"
commit_file "$bad_subject_repo" "Add valid commit before invalid subject"
commit_file "$bad_subject_repo" "Dev"
commit_file "$bad_subject_repo" "Implement workflow metadata checks"
run_in_repo "$bad_subject_repo" commits origin/dev
if [ "$checker_rc" -eq 1 ] && printf '%s\n' "$checker_out" | grep -Fq "invalid commit subject"; then
  pass "buried invalid commit subject is rejected"
else
  fail "buried invalid commit subject is rejected (rc=$checker_rc)"
  printf '%s\n' "$checker_out"
fi

git -C "$valid_repo" switch -q dev
run_in_repo "$valid_repo" all origin/dev
if [ "$checker_rc" -eq 1 ] && printf '%s\n' "$checker_out" | grep -Fq "protected"; then
  pass "all check rejects a protected branch"
else
  fail "all check rejects a protected branch (rc=$checker_rc)"
  printf '%s\n' "$checker_out"
fi
git -C "$valid_repo" switch --detach -q
run_in_repo "$valid_repo" all origin/dev
if [ "$checker_rc" -eq 1 ] && printf '%s\n' "$checker_out" | grep -Fq "detached or empty"; then
  pass "all check rejects a detached checkout"
else
  fail "all check rejects a detached checkout (rc=$checker_rc)"
  printf '%s\n' "$checker_out"
fi
git -C "$valid_repo" switch -q xor/workflow
run_in_repo "$bad_subject_repo" all origin/dev
if [ "$checker_rc" -eq 1 ] && printf '%s\n' "$checker_out" | grep -Fq "invalid commit subject"; then
  pass "all check propagates commit-range failure"
else
  fail "all check propagates commit-range failure (rc=$checker_rc)"
  printf '%s\n' "$checker_out"
fi

bad_name_repo="$work/bad-name-repo"
make_repo "$bad_name_repo" "another-author" "127287135+xormania@users.noreply.github.com"
set_author "$bad_name_repo" "xormania" "127287135+xormania@users.noreply.github.com"
commit_file "$bad_name_repo" "Add valid commit before invalid author"
set_author "$bad_name_repo" "another-author" "127287135+xormania@users.noreply.github.com"
commit_file "$bad_name_repo" "Implement workflow metadata checks"
set_author "$bad_name_repo" "xormania" "127287135+xormania@users.noreply.github.com"
commit_file "$bad_name_repo" "Add valid tip after invalid author"
run_in_repo "$bad_name_repo" commits origin/dev
if [ "$checker_rc" -eq 1 ] && printf '%s\n' "$checker_out" | grep -Fq "sole author must be xormania"; then
  pass "wrong introduced author name is rejected"
else
  fail "wrong introduced author name is rejected (rc=$checker_rc)"
  printf '%s\n' "$checker_out"
fi

bad_email_repo="$work/bad-email-repo"
make_repo "$bad_email_repo" "xormania" "another@example.invalid"
set_author "$bad_email_repo" "xormania" "127287135+xormania@users.noreply.github.com"
commit_file "$bad_email_repo" "Add valid commit before invalid email"
set_author "$bad_email_repo" "xormania" "another@example.invalid"
commit_file "$bad_email_repo" "Implement workflow metadata checks"
set_author "$bad_email_repo" "xormania" "127287135+xormania@users.noreply.github.com"
commit_file "$bad_email_repo" "Add valid tip after invalid email"
run_in_repo "$bad_email_repo" commits origin/dev
if [ "$checker_rc" -eq 1 ] && printf '%s\n' "$checker_out" | grep -Fq "sole author must be xormania"; then
  pass "wrong introduced author email is rejected"
else
  fail "wrong introduced author email is rejected (rc=$checker_rc)"
  printf '%s\n' "$checker_out"
fi

for trailer in co-AUTHORED-by gEnErAtEd-By ASSISTED-BY; do
  trailer_repo="$work/$trailer-repo"
  make_repo "$trailer_repo"
  commit_file "$trailer_repo" "Add valid commit before invalid trailer"
  printf 'trailer\n' >> "$trailer_repo/file.txt"
  git -C "$trailer_repo" add file.txt
  git -C "$trailer_repo" commit -qm \
    "$(printf 'Implement workflow metadata checks\n\n%s: Helper <helper@example.invalid>' "$trailer")"
  commit_file "$trailer_repo" "Add valid tip after invalid trailer"
  run_in_repo "$trailer_repo" commits origin/dev
  if [ "$checker_rc" -eq 1 ] && printf '%s\n' "$checker_out" | grep -Fq "attribution trailer"; then
    pass "$trailer attribution trailer is rejected"
  else
    fail "$trailer attribution trailer is rejected (rc=$checker_rc)"
    printf '%s\n' "$checker_out"
  fi
done

foreign_committer_repo="$work/foreign-committer-repo"
make_repo "$foreign_committer_repo"
printf 'foreign committer\n' >> "$foreign_committer_repo/file.txt"
git -C "$foreign_committer_repo" add file.txt
GIT_AUTHOR_NAME=xormania \
GIT_AUTHOR_EMAIL=127287135+xormania@users.noreply.github.com \
GIT_COMMITTER_NAME=automation \
GIT_COMMITTER_EMAIL=automation@example.invalid \
  git -C "$foreign_committer_repo" commit -qm "Implement workflow metadata checks"
run_in_repo "$foreign_committer_repo" commits origin/dev
if [ "$checker_rc" -eq 0 ] && printf '%s\n' "$checker_out" | grep -Fq "commits=1"; then
  pass "non-xormania committer does not change sole author attribution"
else
  fail "non-xormania committer does not change sole author attribution (rc=$checker_rc)"
  printf '%s\n' "$checker_out"
fi

foreign_base_repo="$work/foreign-base-repo"
make_repo "$foreign_base_repo" "another-author" "another@example.invalid"
set_author "$foreign_base_repo" "xormania" "127287135+xormania@users.noreply.github.com"
commit_file "$foreign_base_repo" "Implement workflow metadata checks"
run_in_repo "$foreign_base_repo" commits origin/dev
if [ "$checker_rc" -eq 0 ] && printf '%s\n' "$checker_out" | grep -Fq "commits=1"; then
  pass "non-xormania base commit is outside introduced attribution checks"
else
  fail "non-xormania base commit is outside introduced attribution checks (rc=$checker_rc)"
  printf '%s\n' "$checker_out"
fi

run_in_repo "$valid_repo" commits refs/heads/absent
if [ "$checker_rc" -eq 125 ] && printf '%s\n' "$checker_out" | grep -Fq "invalid base"; then
  pass "invalid commit base is infrastructure"
else
  fail "invalid commit base is infrastructure (rc=$checker_rc)"
  printf '%s\n' "$checker_out"
fi

run_in_repo "$valid_repo" pr-title xor/workflow
if [ "$checker_rc" -eq 1 ] && printf '%s\n' "$checker_out" | grep -Fq "head branch"; then
  pass "exact head-branch PR title is rejected"
else
  fail "exact head-branch PR title is rejected (rc=$checker_rc)"
  printf '%s\n' "$checker_out"
fi

expected_passes=87
if [ "$passes" -ne "$expected_passes" ]; then
  fail "contract executed the exact expected assertions ($passes/$expected_passes)"
fi
printf 'SUMMARY pass=%s fail=%s\n' "$passes" "$failures"
[ "$failures" -eq 0 ]
