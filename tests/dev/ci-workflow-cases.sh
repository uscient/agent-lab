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
  if [ -n "$block" ] && printf '%s\n' "$block" | grep -Fq -- "$text"; then
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
require_job_text fast 'valid_group()' \
  "fast job bounds the reserved group namespace"
require_job_text fast '[ "$PR_HEAD_REF" = "group/$group_name" ] && valid_group "$group_name"' \
  "fast job enforces group to flow topology"
require_job_text fast '[[ "$PR_HEAD_REF" =~ ^slice/group/$group_name/$component$ ]]' \
  "fast job enforces matching group-slice topology"
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
  trap 'find "$work_dir" -depth -delete >/dev/null 2>&1 || true' EXIT
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
  run_ci_mutant bypass-reducer \
    's#run: ./scripts/dev/required-gates#run: true#'
  run_ci_mutant codeql-omit-flow \
    "s/branches: \[dev, flow, master, main\]/branches: [dev, master, main]/" codeql
fi

printf 'SUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
