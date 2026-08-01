#!/usr/bin/env bash
set -euo pipefail

# Docker-free source contract for the GitHub Actions control plane. This intentionally
# checks a small set of stable, security-relevant invariants rather than attempting to
# implement a general YAML parser.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
ci="$repo_root/.github/workflows/ci.yml"
codeql="$repo_root/.github/workflows/codeql.yml"
ci_fast="$repo_root/scripts/dev/ci-fast"
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

if [ "$(grep -Fxc '    branches: [dev, master, main]' "$ci")" -eq 2 ]; then
  pass "CI runs for pushes and pull requests on every integration branch"
else
  fail "CI runs for pushes and pull requests on every integration branch"
fi
if [ "$(grep -Fxc '    branches: [dev, master, main]' "$codeql")" -eq 2 ]; then
  pass "CodeQL runs for pushes and pull requests on every integration branch"
else
  fail "CodeQL runs for pushes and pull requests on every integration branch"
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
require_job_text fast './scripts/dev/ci-fast' \
  "fast job exposes the canonical local replay command"
require_job_text fast 'git merge-base --is-ancestor "$base" HEAD' \
  "fast job proves the diff base is an ancestor"
require_job_text fast '^([0-9a-f]{40}|[0-9a-f]{64})$' \
  "fast job validates the event SHA grammar"
require_job_text fast 'merge_group) base="$MERGE_GROUP_BASE_SHA"' \
  "fast job resolves the immutable merge-group base"
if [ -x "$ci_fast" ] &&
   awk '
     /scripts\/dev\/cue-tool provision/ { provision=NR }
     /scripts\/dev\/check default quick/ { check=NR }
     END { exit !(provision > 0 && check > provision) }
   ' "$ci_fast"; then
  pass "canonical Fast replay provisions pinned CUE before the gate"
else
  fail "canonical Fast replay provisions pinned CUE before the gate"
fi

require_job_text static '    name: Static' "static job has a stable display name"
require_job_text static '    timeout-minutes: 15' "static job has a bounded runtime"
require_job_text static './tools/validate.sh --strict' \
  "static job exposes the canonical local replay command"

require_job_text docker '    name: Docker security' \
  "Docker job has a stable display name"
require_job_text docker '    timeout-minutes: 45' "Docker job has a bounded runtime"
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

printf 'SUMMARY failures=%s\n' "$failures"
[ "$failures" -eq 0 ]
