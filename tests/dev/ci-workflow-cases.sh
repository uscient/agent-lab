#!/usr/bin/env bash
set -euo pipefail

# Docker-free source contract for the GitHub Actions control plane. This intentionally
# checks a small set of stable, security-relevant invariants rather than attempting to
# implement a general YAML parser.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
ci="${AGENT_LAB_CI_WORKFLOW:-$repo_root/.github/workflows/ci.yml}"
codeql="${AGENT_LAB_CODEQL_WORKFLOW:-$repo_root/.github/workflows/codeql.yml}"
ci_fast="$repo_root/scripts/dev/ci-fast"
agents="$repo_root/AGENTS.md"
workstreams_doc="$repo_root/docs/workstreams.md"
development_doc="$repo_root/docs/development.md"
ci_doc="$repo_root/docs/ci.md"
r0_sha="9ef827c1b0c947babd90ed251deefcd50c04947c"
failures=0

pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

require_text() {
  local file="$1" text="$2" name="$3"
  if grep -Fq -- "$text" "$file"; then
    pass "$name"
  else
    fail "$name"
  fi
}

job_block() {
  local file="$1" job="$2"
  awk -v header="  ${job}:" '
    $0 == header {
      found=1
      print
      next
    }
    found && $0 ~ /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { exit }
    found { print }
  ' "$file"
}

require_job_text() {
  local job="$1" text="$2" name="$3" block
  block="$(job_block "$ci" "$job")"
  # Avoid `producer | grep -q` under pipefail: an early match may SIGPIPE the
  # producer and turn a true assertion into a scheduler-dependent failure.
  if [ -n "$block" ] && grep -Fq -- "$text" <<<"$block"; then
    pass "$name"
  else
    fail "$name"
  fi
}

require_pinned_actions() {
  local file="$1" ref total=0
  while IFS= read -r ref; do
    total=$((total + 1))
    ref="${ref#*@}"
    ref="${ref%%[[:space:]#]*}"
    if [[ ! "$ref" =~ ^[0-9a-f]{40}$ ]]; then
      fail "every action in ${file#"$repo_root/"} is pinned to a full commit"
      return
    fi
  done < <(grep -E '^[[:space:]]*- uses: ' "$file")
  if [ "$total" -gt 0 ]; then
    pass "every action in ${file#"$repo_root/"} is pinned to a full commit"
  else
    fail "${file#"$repo_root/"} declares at least one action"
  fi
}

job_has_fail_closed_tee() {
  local job="$1"
  job_block "$ci" "$job" | awk '
    /set -o pipefail/ {
      pipefail_enabled=1
    }
    /\| tee / {
      pipelines++
      if (!pipefail_enabled) {
        exit 1
      }
    }
    END {
      if (pipelines != 1) {
        exit 1
      }
    }
  '
}

for workflow in "$ci" "$codeql"; do
  if [ -f "$workflow" ]; then
    pass "${workflow#"$repo_root/"} exists"
  else
    fail "${workflow#"$repo_root/"} exists"
  fi
done

if [ "$(sed -n '1p' "$ci")" = "name: CI" ]; then
  pass "CI workflow keeps the stable branch-protection name"
else
  fail "CI workflow keeps the stable branch-protection name"
fi
if [ "$(sed -n '1p' "$codeql")" = "name: CodeQL" ]; then
  pass "CodeQL workflow keeps its stable check name"
else
  fail "CodeQL workflow keeps its stable check name"
fi
if job_block "$codeql" analyze | grep -Fq '    name: CodeQL'; then
  pass "CodeQL job keeps its stable rollup name"
else
  fail "CodeQL job keeps its stable rollup name"
fi

if [ "$(grep -Fxc '    branches: [dev, flow, master, main]' "$ci")" -eq 1 ] &&
   [ "$(grep -Fxc "    branches: [dev, flow, master, main, 'work/**', 'group/**']" "$ci")" -eq 1 ]; then
  pass "CI runs for flow pushes and every authorized PR base"
else
  fail "CI runs for flow pushes and every authorized PR base"
fi
require_text "$ci" '    types: [opened, synchronize, reopened, edited, ready_for_review]' \
  "PR evidence edits rerun the required workflow"
if [ "$(grep -Fxc '    branches: [dev, flow, master, main]' "$codeql")" -eq 1 ] &&
   [ "$(grep -Fxc "    branches: [dev, flow, master, main, 'work/**', 'group/**']" "$codeql")" -eq 1 ]; then
  pass "CodeQL runs for flow pushes and every authorized PR base"
else
  fail "CodeQL runs for flow pushes and every authorized PR base"
fi
if grep -Fxq '  merge_group:' "$ci" &&
   grep -Fxq '  merge_group:' "$codeql"; then
  pass "CI and CodeQL run for merge-queue candidates"
else
  fail "CI and CodeQL run for merge-queue candidates"
fi
if ! grep -Fq 'pull_request_target:' "$ci" "$codeql"; then
  pass "workflows never grant pull_request_target semantics"
else
  fail "workflows never grant pull_request_target semantics"
fi

require_text "$ci" '  contents: read' "CI has read-only repository permissions"
require_pinned_actions "$ci"
require_pinned_actions "$codeql"

if [ "$(grep -Fxc \
       '          CI_LOG_DIR: ${{ runner.temp }}/agent-lab-ci' "$ci")" -eq 3 ] &&
   ! grep -Fxq \
     '      CI_LOG_DIR: ${{ runner.temp }}/agent-lab-ci' "$ci"; then
  pass "runner context is scoped to executable steps"
else
  fail "runner context is scoped to executable steps"
fi

require_job_text fast '    name: Fast' "fast job has a stable display name"
require_job_text fast '    timeout-minutes: 15' "fast job has a bounded runtime"
require_job_text fast '      diff-base: ${{ steps.diff-base.outputs.base }}' \
  "fast job publishes its immutable base to the aggregate"
require_job_text fast '      tested-head: ${{ steps.diff-base.outputs.head }}' \
  "fast job publishes its tested head to the aggregate"
require_job_text fast '      classification: ${{ steps.fast-gate.outputs.classification }}' \
  "fast job publishes its result classification"
require_job_text fast './scripts/dev/ci-fast' \
  "fast job exposes the canonical local replay command"
require_job_text fast 'git merge-base --is-ancestor "$base" HEAD' \
  "fast job proves the diff base is an ancestor"
require_job_text fast '^([0-9a-f]{40}|[0-9a-f]{64})$' \
  "fast job validates the event SHA grammar"
require_job_text fast 'merge_group) base="$MERGE_GROUP_BASE_SHA"' \
  "fast job resolves the immutable merge-group base"
require_job_text fast "          FLOW_R0_SHA: $r0_sha" \
  "fast job pins the immutable R0 bootstrap ancestor"
require_job_text fast \
  'GIT_NO_REPLACE_OBJECTS=1 git merge-base --is-ancestor "$FLOW_R0_SHA" "$dev_head"' \
  "fast job proves the bootstrap closure contains R0"
require_job_text fast '[ "$head" = "$dev_head" ]' \
  "fast job permits only the exact current-dev flow bootstrap closure"
require_job_text fast 'cross-repository PRs are not accepted' \
  "fast job rejects cross-repository evidence"
require_job_text fast \
  './scripts/dev/workflow-check "$evidence_mode" "$body"' \
  "fast job validates the actual PR evidence"
require_job_text fast \
  '"$PR_BASE_SHA" "$PR_HEAD_SHA" "$PR_HEAD_REF" "$PR_BASE_REF"' \
  "fast job binds evidence to immutable identities and route"
require_job_text fast 'flow | group/* | work/*) evidence_mode=pr-body-strict' \
  "program PR evidence cannot waive adversarial fields"
require_job_text fast '"$PR_BASE_SHA:policy/protected.paths"' \
  "fast job reads evidence applicability from the base policy"
require_job_text fast '"$GITHUB_EVENT_PATH"' \
  "fast job reads untrusted PR prose only from the event file"
require_job_text fast 'payload.get("changes", {}).get("body", {}).get("from")' \
  "fast job reads the prior body for append-only edits"
require_job_text fast './scripts/dev/workflow-check evidence-append "$old_body" "$body"' \
  "fast job prevents prior evidence from being erased"
require_job_text fast 'evidence_repair_applies()' \
  "fast job names one bounded repair route for a published invalid cycle"
require_job_text fast '[ "$evidence_mode" = pr-body-strict ] || return 1' \
  "bounded repair is unreachable outside strict evidence applicability"
require_job_text fast './scripts/dev/workflow-check pr-body-strict "$body"' \
  "bounded repair strictly validates the replacement against this event"
require_job_text fast './scripts/dev/workflow-check pr-body-strict "$old_body"' \
  "bounded repair rechecks the published body against the same event"
require_job_text fast 'case "$published_rc" in' \
  "bounded repair requires an assertion-class published failure"
require_job_text fast '*) return "$replacement_rc" ;;' \
  "replacement infrastructure failures remain infrastructure failures"
require_job_text fast '*) return "$published_rc" ;;' \
  "published-body infrastructure failures remain infrastructure failures"
require_job_text fast './scripts/dev/workflow-check evidence-repair "$old_body" "$body"' \
  "bounded repair proves the correction stays inside the helper bound"
require_job_text fast '> "$append_log" 2>&1 || append_rc=$?' \
  "fast job captures the append attempt instead of failing on it"
require_job_text fast 'case "$append_rc" in' \
  "only an assertion-class append failure can enter the bounded repair route"
require_job_text fast 'cat "$append_log" >&2' \
  "an unrepaired append attempt still reports its real diagnostic"
require_job_text fast 'exit "$append_rc"' \
  "an unrepaired append failure keeps its real result classification"
require_job_text fast '*) exit "$repair_rc" ;;' \
  "repair validation infrastructure failures keep their real result classification"
if job_block "$ci" fast | awk '
  $0 ~ /- name: Validate pull request evidence/ { step = NR }
  step && $0 ~ /^[[:space:]]*evidence_mode=pr-body$/ && !mode { mode = NR }
  step && $0 ~ /evidence_repair_applies\(\)/ { gate = NR }
  step && $0 ~ /\[ "\$evidence_mode" = pr-body-strict \] \|\| return 1/ { applicable = NR }
  step && $0 ~ /workflow-check pr-body-strict "\$body"/ { replacement = NR }
  step && $0 ~ /workflow-check pr-body-strict "\$old_body"/ { published = NR }
  step && $0 ~ /case "\$published_rc" in/ { assertion = NR }
  step && $0 ~ /workflow-check evidence-repair "\$old_body" "\$body"/ { repair = NR }
  step && $0 ~ /workflow-check evidence-append "\$old_body" "\$body"/ { attempt = NR }
  step && $0 ~ /case "\$append_rc" in/ { append_class = NR }
  step && $0 ~ /evidence_repair_applies \|\| repair_rc=\$\?/ { consulted = NR }
  step && $0 ~ /workflow-check "\$evidence_mode" "\$body"/ { final = NR }
  END {
    exit !(step > 0 && mode > step && gate > mode && applicable > gate &&
           replacement > applicable && published > replacement &&
           assertion > published && repair > assertion &&
           attempt > repair && append_class > attempt &&
           consulted > append_class && final > consulted)
  }
'; then
  pass "fast job orders applicability, replacement, published, and repair before the ruling check"
else
  fail "fast job orders applicability, replacement, published, and repair before the ruling check"
fi
require_job_text fast 'valid_group()' \
  "fast job bounds the reserved group namespace"
require_job_text fast '[ "$PR_HEAD_REF" = "group/$group_name" ] && valid_group "$group_name"' \
  "fast job enforces group to flow topology"
require_job_text fast '[[ "$PR_HEAD_REF" =~ ^slice/group/$group_name/$component$ ]]' \
  "fast job enforces matching group-slice topology"
require_text "$agents" 'receives changes only through matching group-slice PRs' \
  "agent policy makes Group branches PR-only integration parents"
require_text "$workstreams_doc" 'at least two independently GREEN vertical slices' \
  "program guide requires multiple vertical slices after G0"
require_text "$workstreams_doc" \
  'A process-only synchronization or gate-registration slice does not' \
  "program guide excludes process-only slices from the vertical-slice minimum"
require_text "$workstreams_doc" \
  'ignored packet state is never shared between checkouts' \
  "program guide isolates each active slice's workflow packet"
require_text "$workstreams_doc" './scripts/dev/workstream group-sync' \
  "program guide routes moving Flow through a Group synchronization slice"
require_text "$development_doc" 'PR-only `group-sync` slice from `origin/flow`' \
  "development guide matches the PR-only Group synchronization route"
require_text "$workstreams_doc" \
  'The required workflow applies the same' \
  "program guide records hosted parity for the bounded evidence repair"
require_text "$workstreams_doc" 'completes its own exact-head hosted campaign' \
  "program guide states the repair edit passes its own exact-head campaign"
require_text "$development_doc" 'completes its own exact-head hosted campaign in that one run' \
  "development guide states the repair edit passes its own exact-head campaign"
if ! grep -Fq 'fails that run' "$workstreams_doc" &&
   ! grep -Fq 'becomes green on the next run' "$workstreams_doc"; then
  pass "program guide no longer sends a repair edit to a later pushed run"
else
  fail "program guide no longer sends a repair edit to a later pushed run"
fi
require_text "$workstreams_doc" 'Claude Opus 5 at `max`' \
  "program guide pins the corrected Claude effort"
require_text "$workstreams_doc" 'Never launch a status worker' \
  "program guide requires direct unattended worker observation"
if [ -x "$ci_fast" ] &&
   awk '
     /scripts\/dev\/cue-tool provision/ { cue=NR }
     /scripts\/dev\/cedar-tool provision/ { cedar=NR }
     /scripts\/dev\/check default quick/ { check=NR }
     END { exit !(cue > 0 && cedar > cue && check > cedar) }
   ' "$ci_fast"; then
  pass "canonical Fast replay provisions pinned CUE and Cedar before the gate"
else
  fail "canonical Fast replay provisions pinned CUE and Cedar before the gate"
fi
require_job_text fast 'sudo apt-get install -y -qq bubblewrap shellcheck' \
  "Fast runner provisions bubblewrap before the security gate"
if job_block "$ci" fast | awk '
  /- name: Verify Fast gate bubblewrap isolation/ { step=NR }
  /if ! bwrap_probe/ { initial=NR }
  /sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0/ { enable=NR }
  /^[[:space:]]*bwrap_probe[[:space:]]*$/ { verify=NR }
  END { exit !(step > 0 && initial > step && enable > initial && verify > enable) }
'; then
  pass "Fast runner proves bubblewrap isolation after a bounded Ubuntu user-namespace correction"
else
  fail "Fast runner proves bubblewrap isolation after a bounded Ubuntu user-namespace correction"
fi

require_job_text static '    name: Static' "static job has a stable display name"
require_job_text static '    timeout-minutes: 15' "static job has a bounded runtime"
require_job_text static '      tested-head: ${{ steps.identity.outputs.head }}' \
  "static job publishes its tested head"
require_job_text static '      classification: ${{ steps.static-gate.outputs.classification }}' \
  "static job publishes its result classification"
require_job_text static './tools/validate.sh --strict' \
  "static job exposes the canonical local replay command"

require_job_text docker '    name: Docker security' \
  "Docker job has a stable display name"
require_job_text docker '    timeout-minutes: 45' "Docker job has a bounded runtime"
require_job_text docker '      tested-head: ${{ steps.identity.outputs.head }}' \
  "Docker job publishes its tested head"
require_job_text docker '      classification: ${{ steps.docker-gate.outputs.classification }}' \
  "Docker job publishes its result classification"
require_job_text docker './scripts/dev/docker-gate' \
  "Docker job exposes the canonical local replay command"
require_job_text docker 'docker/build-push-action@' \
  "Docker job uses the supported BuildKit cache integration"
require_job_text docker 'cache-from: type=gha,scope=devbox' \
  "Docker job restores the explicitly scoped devbox cache"
require_job_text docker 'cache-to: type=gha,mode=max,scope=devbox' \
  "Docker job persists the explicitly scoped devbox cache"
require_job_text docker 'AGENT_LAB_DEVBOX_PREBUILT: 1' \
  "Docker gate verifies the image built by the cache-aware step"
if ! job_block "$ci" docker | grep -Eq 'run_gate=false|reused-pr-merge'; then
  pass "required Docker CI never self-skips without runtime evidence"
else
  fail "required Docker CI never self-skips without runtime evidence"
fi
if ! job_block "$ci" docker | grep -Fqi 'openclaw'; then
  pass "required Docker CI never builds OpenClaw"
else
  fail "required Docker CI never builds OpenClaw"
fi
if job_has_fail_closed_tee fast &&
   job_has_fail_closed_tee static &&
   job_has_fail_closed_tee docker; then
  pass "every logged gate propagates failures through tee"
else
  fail "every logged gate propagates failures through tee"
fi

require_job_text required-gates '    name: Required gates' \
  "aggregate job has a stable branch-protection name"
require_job_text required-gates '    if: ${{ always() }}' \
  "aggregate job runs after failed, skipped, or cancelled dependencies"
require_job_text required-gates '    needs: [fast, static, docker]' \
  "aggregate job names every required worker"
require_job_text required-gates 'CI_NEEDS_JSON: ${{ toJSON(needs) }}' \
  "aggregate job passes structured dependency state to the reducer"
require_job_text required-gates 'CI_EXPECTED_HEAD: ${{ github.sha }}' \
  "aggregate job binds every worker to the event head"
require_job_text required-gates './scripts/dev/required-gates' \
  "aggregate job uses the versioned fail-closed reducer"

if [ "$(grep -Fc 'actions/upload-artifact@' "$ci")" -eq 3 ]; then
  pass "each worker retains its produced gate log on failure"
else
  fail "each worker retains its produced gate log on failure"
fi
if [ "$(grep -Fc 'retention-days: 7' "$ci")" -eq 3 ]; then
  pass "failure artifacts have an explicit short retention"
else
  fail "failure artifacts have an explicit short retention"
fi
if [ "$(grep -Fc '${{ github.run_id }}-${{ github.run_attempt }}' "$ci")" -eq 3 ]; then
  pass "failure artifact names remain unique across reruns"
else
  fail "failure artifact names remain unique across reruns"
fi
if [ "$(grep -Fc 'GITHUB_STEP_SUMMARY' "$ci")" -ge 3 ]; then
  pass "worker and aggregate results publish navigable summaries"
else
  fail "worker and aggregate results publish navigable summaries"
fi
if ! grep -Fq 'git rev-parse HEAD^' "$ci"; then
  pass "diff-base selection has no implicit HEAD fallback"
else
  fail "diff-base selection has no implicit HEAD fallback"
fi

for doctrine in "$agents" "$workstreams_doc" "$development_doc" "$ci_doc"; do
  if { grep -Fq 'bootstrap-closure `dev` commit' "$doctrine" ||
       grep -Fq 'exact closure commit' "$doctrine"; } &&
     ! grep -Fq 'exact R0-updated `dev`' "$doctrine"; then
    pass "${doctrine#"$repo_root/"} binds flow creation to the bootstrap closure"
  else
    fail "${doctrine#"$repo_root/"} binds flow creation to the bootstrap closure"
  fi
done
if ! grep -Eq '^[[:space:]]*(paths|paths-ignore):' "$ci" "$codeql" &&
   ! grep -Fq 'continue-on-error:' "$ci" "$codeql"; then
  pass "required workflow scope has no path filter or continue-on-error escape"
else
  fail "required workflow scope has no path filter or continue-on-error escape"
fi
if [ "$(grep -Fxc '            125) classification=infrastructure ;;' "$ci")" -eq 3 ] &&
   [ "$(grep -Fc 'classification=%s\n' "$ci")" -eq 3 ]; then
  pass "every worker preserves assertion and infrastructure result classes"
else
  fail "every worker preserves assertion and infrastructure result classes"
fi

# The edited pull_request event is the only run that sees both the published and the replacement
# ledger, so the hosted bounded repair is proved against the workflow's own step body rather than
# its prose. Replay the exact "Validate pull request evidence" script against synthetic events.
# Nothing below contacts GitHub, Docker, or the network.
replay_dir="$(mktemp -d)"
trap 'find "$replay_dir" -depth -delete >/dev/null 2>&1 || true' EXIT
evidence_step="$replay_dir/evidence-step.sh"
# Blank lines are held back until real content follows them, so the extraction reproduces the YAML
# block scalar exactly instead of trailing the blank line that ends it.
awk '
  $0 == "      - name: Validate pull request evidence" { step = 1; next }
  step && $0 == "        run: |" { body = 1; next }
  body && $0 ~ /^[[:space:]]*$/ { pending++; next }
  body && $0 !~ /^          / { exit }
  body {
    for (; pending > 0; pending--) print ""
    print substr($0, 11)
  }
' "$ci" > "$evidence_step"
if [ -s "$evidence_step" ] && bash -n "$evidence_step" 2>/dev/null; then
  pass "the pull request evidence step body extracts as a runnable script"
else
  fail "the pull request evidence step body extracts as a runnable script"
fi

cat > "$replay_dir/write-event.py" <<'PY'
import json
import pathlib
import sys

target, body_file, old_body_file = sys.argv[1], sys.argv[2], sys.argv[3]
payload = {"pull_request": {"body": pathlib.Path(body_file).read_text(encoding="utf-8")}}
if old_body_file:
    payload["changes"] = {"body": {"from": pathlib.Path(old_body_file).read_text(encoding="utf-8")}}
pathlib.Path(target).write_text(json.dumps(payload), encoding="utf-8")
PY

cat > "$replay_dir/body.template" <<'EOF'
## Summary

Accept one bounded published-evidence repair on the edited event.

## Motivation / Context

A pull request body is published before any required check can reject its first cycle.

## Changes

- accept the bounded repair inside the edited run;
- keep byte-exact append-only as the default route.

## Testing

- `bash tests/dev/ci-workflow-cases.sh` — pass.

## Evidence

### Cycle 1

- Route: `@HEAD_REF@` -> `@BASE_REF@`
- Base: `@BASE_SHA@`
- Head: `@HEAD_SHA@`
- Scenarios: `CI-EVIDENCE-REPAIR`
- Assertions: `CI-EVIDENCE-REPAIR-RC`
- RED predecessor: @PREDECESSOR@
- RED: `bash tests/dev/ci-workflow-cases.sh` — rc=1 classification=assertion-failure
- GREEN: `bash tests/dev/ci-workflow-cases.sh` — rc=0 classification=success
- Product mutation: `waive-repair-applicability` — detected rc=1 classification=assertion-failure
- CI mutation: `bypass-repair-evidence-rule` — detected rc=1 classification=assertion-failure
- Runner: `ubuntu-latest`
- Duration: `6s`
- Cleanup: `replay state removed`
- Artifacts: `none retained`
- Unverified: `none`
EOF

write_replay_body() {
  local target="$1" head_ref="$2" base_ref="$3" base_sha="$4" head_sha="$5" predecessor="$6"
  sed -e "s|@HEAD_REF@|$head_ref|g" -e "s|@BASE_REF@|$base_ref|g" \
    -e "s|@BASE_SHA@|$base_sha|g" -e "s|@HEAD_SHA@|$head_sha|g" \
    -e "s|@PREDECESSOR@|$predecessor|g" "$replay_dir/body.template" > "$target"
}

run_evidence_step() {
  local body_file="$1" old_body_file="$2" head_ref="$3" base_ref="$4" \
    base_sha="$5" head_sha="$6" rc=0
  : > "$replay_dir/output"
  python3 "$replay_dir/write-event.py" "$replay_dir/event.json" "$body_file" \
    "$old_body_file" || return 125
  # TMPDIR is redirected so every temporary file the replayed step and its checks allocate stays
  # inside this suite's own cleaned state.
  (
    cd "$repo_root" &&
      TMPDIR="$replay_dir" PR_BASE_SHA="$base_sha" PR_HEAD_SHA="$head_sha" \
      PR_BASE_REF="$base_ref" PR_HEAD_REF="$head_ref" \
      GITHUB_EVENT_PATH="$replay_dir/event.json" \
      bash -e "$evidence_step"
  ) > "$replay_dir/output" 2>&1 || rc=$?
  return "$rc"
}

# Each expectation is required text, or forbidden text when prefixed with "!".
expect_evidence_step() {
  local name="$1" expected_rc="$2" body_file="$3" old_body_file="$4" \
    head_ref="$5" base_ref="$6" base_sha="$7" head_sha="$8" rc=0 expectation
  shift 8
  run_evidence_step "$body_file" "$old_body_file" "$head_ref" "$base_ref" \
    "$base_sha" "$head_sha" || rc=$?
  if [ "$rc" -ne "$expected_rc" ]; then
    fail "$name (rc=$rc)"
    return
  fi
  for expectation in "$@"; do
    case "$expectation" in
      '!'*)
        if grep -Fq -- "${expectation#!}" "$replay_dir/output"; then
          fail "$name"
          return
        fi
        ;;
      *)
        if ! grep -Fq -- "$expectation" "$replay_dir/output"; then
          fail "$name"
          return
        fi
        ;;
    esac
  done
  pass "$name"
}

replay_base_sha="4444444444444444444444444444444444444444"
replay_head_sha="5555555555555555555555555555555555555555"
replay_predecessor='`3333333333333333333333333333333333333333`'
replay_na_predecessor='N/A — this replay route has no recorded predecessor'
strict_head_ref="slice/group/g0-operator-surface/evidence"
strict_base_ref="group/g0-operator-surface"
repair_pass='PASS workflow bounded evidence repair of the published cycle'
append_pass='PASS workflow append-only evidence'
append_fail='FAIL workflow PR evidence update changed or erased a prior cycle'
body_pass='PASS workflow PR body'

strict_valid_body="$replay_dir/strict-valid.md"
write_replay_body "$strict_valid_body" "$strict_head_ref" "$strict_base_ref" \
  "$replay_base_sha" "$replay_head_sha" "$replay_predecessor"
# The published first cycle ends its canonical RED and GREEN results with comma-adjacent prose.
strict_published_body="$replay_dir/strict-published.md"
sed -e '/^- RED:/s/$/, including the CI-EVIDENCE-REPAIR predecessor/' \
  -e '/^- GREEN:/s/$/, 22\/22 assertions/' "$strict_valid_body" > "$strict_published_body"
# A published cycle that already passes the same strict validation has nothing to repair.
strict_redundant_body="$replay_dir/strict-redundant.md"
sed '/^- GREEN:/s/$/, rc=0 classification=success/' "$strict_valid_body" > "$strict_redundant_body"
# A correction that also rewrites a non-result field is outside the bounded repair.
strict_widened_body="$replay_dir/strict-widened.md"
sed 's/^- Scenarios: .*/- Scenarios: `CI-EVIDENCE-REPAIR-WIDENED`/' \
  "$strict_valid_body" > "$strict_widened_body"
strict_appended_body="$replay_dir/strict-appended.md"
{
  cat "$strict_valid_body"
  sed -n '/^### Cycle 1$/,$p' "$strict_valid_body" | sed 's/^### Cycle 1$/### Cycle 2/'
} > "$strict_appended_body"
# A reasoned N/A predecessor passes pr-body and fails pr-body-strict, so a replacement carrying it
# is the exact replacement the strict precondition has to reject.
weak_body="$replay_dir/strict-weak-replacement.md"
write_replay_body "$weak_body" "$strict_head_ref" "$strict_base_ref" \
  "$replay_base_sha" "$replay_head_sha" "$replay_na_predecessor"
weak_published_body="$replay_dir/strict-weak-published.md"
sed -e '/^- RED:/s/$/, prose/' -e '/^- GREEN:/s/$/, prose/' "$weak_body" > "$weak_published_body"

expect_evidence_step \
  "an edited event repairs its published invalid cycle inside that same run" \
  0 "$strict_valid_body" "$strict_published_body" "$strict_head_ref" "$strict_base_ref" \
  "$replay_base_sha" "$replay_head_sha" \
  "$repair_pass" "$body_pass" "!$append_fail"
expect_evidence_step \
  "an ordinary appended cycle keeps the byte-exact append-only default" \
  0 "$strict_appended_body" "$strict_valid_body" "$strict_head_ref" "$strict_base_ref" \
  "$replay_base_sha" "$replay_head_sha" \
  "$append_pass" "$body_pass" "!$repair_pass"
expect_evidence_step \
  "a published cycle that still passes strict validation cannot be repaired" \
  1 "$strict_valid_body" "$strict_redundant_body" "$strict_head_ref" "$strict_base_ref" \
  "$replay_base_sha" "$replay_head_sha" \
  "$append_fail" "!$repair_pass"
expect_evidence_step \
  "a replacement failing the same strict validation cannot be repaired" \
  1 "$weak_body" "$weak_published_body" "$strict_head_ref" "$strict_base_ref" \
  "$replay_base_sha" "$replay_head_sha" \
  "$append_fail" "!$repair_pass"
expect_evidence_step \
  "a correction wider than the bounded repair keeps its append-only failure" \
  1 "$strict_widened_body" "$strict_published_body" "$strict_head_ref" "$strict_base_ref" \
  "$replay_base_sha" "$replay_head_sha" \
  "$append_fail" "!$repair_pass"

# A non-strict pull request never reaches the repair route. Comparing the current repository head
# against itself keeps the changed-path classification empty and the applicability deterministic.
replay_repo_sha="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)"
nonstrict_valid_body="$replay_dir/nonstrict-valid.md"
write_replay_body "$nonstrict_valid_body" xor/workflow dev \
  "$replay_repo_sha" "$replay_repo_sha" "$replay_predecessor"
nonstrict_published_body="$replay_dir/nonstrict-published.md"
sed -e '/^- RED:/s/$/, prose/' -e '/^- GREEN:/s/$/, prose/' \
  "$nonstrict_valid_body" > "$nonstrict_published_body"
if [[ "$replay_repo_sha" =~ ^[0-9a-f]{40}$ ]]; then
  expect_evidence_step \
    "a non-strict pull request cannot reach the bounded repair route" \
    1 "$nonstrict_valid_body" "$nonstrict_published_body" xor/workflow dev \
    "$replay_repo_sha" "$replay_repo_sha" \
    "$append_fail" "!$repair_pass"
else
  fail "a non-strict pull request cannot reach the bounded repair route"
fi

if [ "${CI_WORKFLOW_MUTATION_PROBE:-0}" != 1 ]; then
  run_ci_mutant() {
    local name="$1" expression="$2" target="${3:-ci}"
    local mutant="$work_dir/$name.yml"
    local source="$ci" rc=0
    if [ "$target" = codeql ]; then
      source="$codeql"
    fi
    sed "$expression" "$source" > "$mutant"
    if cmp -s "$source" "$mutant"; then
      fail "$name mutation is calibrated"
      return
    fi
    if [ "$target" = codeql ]; then
      CI_WORKFLOW_MUTATION_PROBE=1 AGENT_LAB_CI_WORKFLOW="$ci" \
        AGENT_LAB_CODEQL_WORKFLOW="$mutant" bash "$0" > "$work_dir/$name.out" 2>&1 || rc=$?
    else
      CI_WORKFLOW_MUTATION_PROBE=1 AGENT_LAB_CI_WORKFLOW="$mutant" \
        AGENT_LAB_CODEQL_WORKFLOW="$codeql" bash "$0" > "$work_dir/$name.out" 2>&1 || rc=$?
    fi
    if [ "$rc" -eq 1 ] && grep -Eq 'SUMMARY failures=[1-9][0-9]*' "$work_dir/$name.out"; then
      pass "$name mutation turns the workflow contract RED"
    else
      fail "$name mutation turns the workflow contract RED (rc=$rc)"
    fi
  }

  work_dir="$(mktemp -d)"
  trap 'find "$replay_dir" "$work_dir" -depth -delete >/dev/null 2>&1 || true' EXIT
  run_ci_mutant omit-flow-trigger \
    "s/branches: \[dev, flow, master, main\]/branches: [dev, master, main]/"
  run_ci_mutant omit-group-trigger \
    "s/, 'group\/\*\*'//"
  run_ci_mutant allow-continue-on-error \
    '/id: fast-gate/a\        continue-on-error: true'
  run_ci_mutant omit-bubblewrap-provision \
    's/bubblewrap shellcheck/shellcheck/'
  run_ci_mutant omit-bubblewrap-userns-correction \
    '/kernel.apparmor_restrict_unprivileged_userns=0/d'
  run_ci_mutant drop-required-worker \
    's/needs: \[fast, static, docker\]/needs: [fast, static]/'
  run_ci_mutant erase-result-classification \
    '0,/125) classification=infrastructure/s//125) classification=assertion-failure/'
  run_ci_mutant weaken-flow-bootstrap \
    's/\[ "$head" = "$dev_head" \]/[ "$head" != "$dev_head" ]/'
  run_ci_mutant erase-r0-bootstrap-pin \
    "s/$r0_sha/0000000000000000000000000000000000000000/"
  run_ci_mutant bypass-r0-ancestry \
    's/GIT_NO_REPLACE_OBJECTS=1 git merge-base --is-ancestor "$FLOW_R0_SHA" "$dev_head"/true/'
  run_ci_mutant omit-pr-evidence-edit \
    's/, edited//'
  run_ci_mutant bypass-pr-evidence \
    's#./scripts/dev/workflow-check "$evidence_mode" "$body" \\#true #'
  run_ci_mutant waive-program-evidence \
    's/flow | group\/\* | work\/\*) evidence_mode=pr-body-strict/flow | group\/* | work\/*) evidence_mode=pr-body/'
  run_ci_mutant erase-append-only-evidence \
    's#./scripts/dev/workflow-check evidence-append "$old_body" "$body"#true#'
  run_ci_mutant waive-append-assertion-precondition \
    's#case "$append_rc" in#append_rc=1; case "$append_rc" in#'
  run_ci_mutant waive-repair-applicability \
    's#\[ "$evidence_mode" = pr-body-strict \] || return 1#true#'
  run_ci_mutant weaken-repair-replacement \
    's#workflow-check pr-body-strict "$body" \\#workflow-check pr-body "$body" \\#'
  run_ci_mutant bypass-repair-published-precondition \
    's#case "$published_rc" in#published_rc=1; case "$published_rc" in#'
  run_ci_mutant bypass-repair-evidence-rule \
    's#./scripts/dev/workflow-check evidence-repair "$old_body" "$body" >/dev/null 2>&1#true#'
  run_ci_mutant erase-append-diagnostic \
    's#cat "$append_log" >&2#true#'
  run_ci_mutant erase-append-classification \
    's#exit "$append_rc"#exit 0#'
  run_ci_mutant bypass-reducer \
    's#run: ./scripts/dev/required-gates#run: true#'
  run_ci_mutant codeql-omit-flow \
    "s/branches: \[dev, flow, master, main\]/branches: [dev, master, main]/" codeql
fi

printf 'SUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
