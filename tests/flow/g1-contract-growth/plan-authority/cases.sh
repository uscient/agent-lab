#!/usr/bin/env bash
# G1 plan-authority focused suite.
#
# Three frozen contract scenarios are asserted here and nowhere else:
#
#   SEC-PLAN-EXECUTABLE     a verified v0alpha1 plan stays readable evidence but
#                           is explicitly non-executable, while a v0alpha2 plan
#                           is executable-eligible only when every declared
#                           authority field is present and bound,
#   SEC-PLAN-INLINE-SECRET  the closed v0alpha2 authored vocabulary refuses
#                           inline secret values and host secret paths before a
#                           plan is ever published, and
#   SEC-PLAN-SECRET-GRANT   every template grant is a duplicate-free subset of
#                           the plan's declared logical secret references.
#
# Structure of the evidence:
#
#   * CUE structural validation and Cedar authorization are kept apart.  The
#     authored vocabulary is decided by the real repository-pinned CUE against
#     the successor contract root; authorization is decided by the real
#     repository-pinned Cedar through the product's own seam.  Neither result is
#     ever inferred from the other.
#   * The suite never reimplements a projection.  lib/probe.py reports what the
#     product returned through the existing isolated import pattern, and
#     lib/properties.py only states which properties an observed document
#     already has.  Both instruments are calibrated below against documents that
#     are known to violate them, so no "OK" here can be vacuous.
#   * An authorization verdict is bound to the policy it is supposed to come
#     from.  Disposable private copies of this checkout, built under the suite's
#     own temporary tree, ask the product the same question twice under one
#     changed lab install policy.  Each mutation lives in its own copy: the
#     calibration copy varies only the v0alpha1 policy, the successor copy varies
#     only the v0alpha2 policy, and the successor copy is proved byte-identical
#     to the pristine one apart from that single file, so no successor answer can
#     be a reaction to the calibration mutation.  No tracked file is ever
#     written.
#   * Every negative fixture is paired with an adjacent positive control, and
#     every fixture-shaped rule is re-checked against mutants derived at run
#     time, so neither an always-deny implementation nor one that recognises the
#     stored fixtures can pass.
#
# Absence of the successor seam is an assertion result, not a harness fault: the
# tools this suite needs are proved to work first, and only genuinely missing
# tooling, an uncalibratable instrument, or a broken harness raises infra.
#
# Exit contract: 0 with the final marker when every assertion passes, 1 on
# assertion failure, 125 on setup, harness, or calibration uncertainty.
set -u -o pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
repo_root="$(cd -- "$script_dir/../../../.." >/dev/null 2>&1 && pwd)"
fixtures="$script_dir/fixtures"
probe_tool="$script_dir/lib/probe.py"
property_tool="$script_dir/lib/properties.py"
experiment_tool="$repo_root/scripts/experiment.py"
cue_tool="$repo_root/scripts/dev/cue-tool.py"
cedar_tool="$repo_root/scripts/dev/cedar-tool.py"
legacy_fixture="$repo_root/tests/experiment/fixtures/directories/minimal"
successor_contract="$repo_root/contracts/experiment/v0alpha2"
successor_authorization="$repo_root/authorization/experiment/v0alpha2"
# An isolated packet may intentionally omit ignored cache payloads.  Preserve a
# coordinator-supplied pinned-tool location when present, while retaining the
# repository-local cache as the ordinary fallback.  The resolved directories
# are passed explicitly through every clean and private-copy environment below.
cue_tool_dir="${AGENT_LAB_CUE_TOOL_DIR:-$repo_root/.cache/dev/tools/cue}"
cedar_tool_dir="${AGENT_LAB_CEDAR_TOOL_DIR:-$repo_root/.cache/dev/tools/cedar}"

# The one synthetic secret value this suite ever creates.  It is written only
# into the inline-secret fixture; no product channel may ever echo it back.
canary='G1CANARYSECRET4d9b21e7c6a05f38'
# A fixed synthetic contract digest, so the structural drive and the product's
# own derivation are asked the same question with the same tag.
synthetic_digest='1111111111111111111111111111111111111111111111111111111111111111'
zero_digest='sha256:0000000000000000000000000000000000000000000000000000000000000000'
command_timeout=60
expected_count=9
work=""
observed=""
failures=0
infrastructure=0
authored_index=0
project_index=0
seam_present=0
seam_missing=''
# The private-copy policy instrument, and what it is allowed to claim.  Each
# policy mutation gets a copy of its own, so no comparison ever varies two
# policies at once.
private_pristine=''
private_legacy_forbid=''
private_successor_forbid=''
private_copy_ok=0
private_copy_reason='the private-copy policy instrument did not run'
private_evidence_reason='the private-copy mutation evidence did not run'
legacy_policy='authorization/experiment/v0alpha1/operator.cedar'
successor_policy='authorization/experiment/v0alpha2/operator.cedar'
successor_policy_varied=0

# The frozen assertion identities, in the frozen emission order.
expected_ids=(
  WF-PLAN-LEGACY-INSPECTABLE
  SEC-PLAN-EXECUTABLE
  REC-PLAN-AUTHORITY-DENIAL
  SEC-PLAN-INLINE-SECRET
  SEC-PLAN-SECRET-QUIET
  WF-PLAN-SECRET-REFERENCE
  SEC-PLAN-SECRET-GRANT
  WF-PLAN-GRANT-NEIGHBOR
  SEC-PLAN-GRANT-UNKNOWN
)

cleanup_work() {
  local failed=0
  if [ -n "$work" ] && [ -e "$work" ]; then
    find "$work" -type d -exec chmod u+rwx {} + 2>/dev/null || failed=1
    find "$work" -type f -exec chmod u+rw {} + 2>/dev/null || failed=1
    find "$work" -type f -delete 2>/dev/null || failed=1
    find "$work" -type l -delete 2>/dev/null || failed=1
    find "$work" -depth -type d -exec rmdir {} + 2>/dev/null || failed=1
    [ ! -e "$work" ] || failed=1
  fi
  return "$failed"
}

finish() {
  local assertions=0
  if [ -n "$observed" ] && [ -f "$observed" ]; then
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
  printf 'FLOW G1 PLAN AUTHORITY PASS\n'
}

infra_stop() {
  printf 'INFRA %s\n' "$1" >&2
  infrastructure=1
  finish
}

if ! work="$(mktemp -d)"; then
  printf 'SUMMARY assertions=0 expected=%s failures=0 infra=1\n' "$expected_count"
  exit 125
fi
trap 'cleanup_work >/dev/null 2>&1 || true' EXIT
observed="$work/observed"
: > "$observed"

pass() {
  printf 'PASS %s %s\n' "$1" "$2"
  printf '%s\n' "$1" >> "$observed"
}

fail() {
  printf 'FAIL %s %s\n' "$1" "$2"
  printf '%s\n' "$1" >> "$observed"
  failures=$((failures + 1))
}

note() { printf 'NOTE %s %s\n' "$1" "$2" >&2; }

# ---------------------------------------------------------------------------
# Prerequisites.  The successor contract, authorization, and product symbols are
# deliberately NOT prerequisites: their absence is an assertion result.
# ---------------------------------------------------------------------------

if [ ! -f "$probe_tool" ] || [ ! -f "$property_tool" ] || [ ! -d "$fixtures" ] \
   || [ ! -f "$experiment_tool" ] || [ ! -f "$cue_tool" ] || [ ! -f "$cedar_tool" ] \
   || [ ! -d "$legacy_fixture" ] || [ ! -d "$cue_tool_dir" ] || [ ! -d "$cedar_tool_dir" ] \
   || ! command -v python3 >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1 \
   || ! command -v cmp >/dev/null 2>&1 || ! command -v sha256sum >/dev/null 2>&1; then
  infra_stop 'g1 plan-authority prerequisites are unavailable (python3, timeout, cmp, sha256sum, pinned CUE and Cedar payloads)'
fi

mkdir -p "$work/home" "$work/tmp" || infra_stop 'private work boundary could not be created'

# ---------------------------------------------------------------------------
# Bounded capture.  Every product and tool invocation is time-bounded, so a
# wedged successor implementation is uncertainty rather than a hung suite.
# ---------------------------------------------------------------------------

CAPTURE_OUT=""
CAPTURE_ERR=""
CAPTURE_RC=0

capture() {
  local label="$1"
  shift
  CAPTURE_OUT="$work/$label.out"
  CAPTURE_ERR="$work/$label.err"
  CAPTURE_RC=0
  timeout "$command_timeout" "$@" > "$CAPTURE_OUT" 2> "$CAPTURE_ERR" || CAPTURE_RC=$?
}

# The environment every product and pinned-tool invocation sees.  Bytecode
# writing is disabled so the suite leaves no derived artifact beside product
# sources, and the pinned tool directories are named explicitly so a run never
# depends on ambient provisioning.
lab_env=(
  env -i
  PATH=/usr/bin:/bin
  LANG=C
  LC_ALL=C
  PYTHONDONTWRITEBYTECODE=1
  "HOME=$work/home"
  "TMPDIR=$work/tmp"
  "AGENT_LAB_CUE_TOOL_DIR=$cue_tool_dir"
  "AGENT_LAB_CEDAR_TOOL_DIR=$cedar_tool_dir"
)

cue_env=(
  env -i
  PATH=/usr/bin:/bin
  LANG=C
  LC_ALL=C
  PYTHONDONTWRITEBYTECODE=1
  CUE_CACHE_DIR=/dev/null
  CUE_CONFIG_DIR=/dev/null
  CUE_REGISTRY=none
  "TMPDIR=$work/tmp"
  "AGENT_LAB_CUE_TOOL_DIR=$cue_tool_dir"
)

property() { python3 -I -B "$property_tool" "$@"; }

matches_broker_reference() {
  # This is the sole assertion path for the declared name/reference pair.  It is
  # calibrated below on synthetic observations before successor-seam discovery,
  # then replayed unchanged on the real projected plan after GREEN.
  property declared-reference \
    "$1" broker-token agent-lab.secret/broker-token
}

probe() {
  local label="$1"
  shift
  capture "$label" "${lab_env[@]}" python3 -I -B "$probe_tool" "$repo_root" "$@"
}

# ---------------------------------------------------------------------------
# Instruments.
# ---------------------------------------------------------------------------

# The authored vocabulary, evaluated exactly the way the product evaluates an
# authored source tree: the pinned CUE exports the authored value on its own.
# This stage answers "is this a well-formed authored value", never "does it
# satisfy the contract".
authored_export() {
  local fixture="$1" out="$2" root
  root="$work/authored-$authored_index"
  authored_index=$((authored_index + 1))
  if ! mkdir -p "$root/cue.mod" \
     || ! printf 'module: "agent-lab.local/experiment-snapshot"\nlanguage: version: "v0.9.0"\n' \
          > "$root/cue.mod/module.cue" \
     || ! cp "$fixture" "$root/experiment.cue"; then
    printf 'uncertain\n'
    return
  fi
  local rc=0
  timeout "$command_timeout" "${cue_env[@]}" python3 -I -B "$cue_tool" \
    -C "$root" export -E experiment.cue -e experiment --out json \
    > "$out" 2> "$out.err" || rc=$?
  case "$rc" in
    0) if [ -s "$out" ]; then printf 'accept\n'; else printf 'uncertain\n'; fi ;;
    1) printf 'reject\n' ;;
    *) printf 'uncertain\n' ;;
  esac
}

# Structural validation against the successor contract root, driven through the
# real pinned CUE helper with the product's own projection arguments.  This
# stage answers "does this authored value satisfy the closed successor schema,
# and what does the canonical projection say".
schema_project() {
  local input="$1" out="$2" label rc=0
  label="project-$project_index"
  project_index=$((project_index + 1))
  if [ ! -d "$successor_contract" ]; then
    printf 'absent\n'
    return
  fi
  timeout "$command_timeout" "${cue_env[@]}" python3 -I -B "$cue_tool" \
    -C "$successor_contract" export -E schema.cue plan.cue \
    -l 'manifest:' 'json:' - -e '#Plan' \
    -t "contractDigest=sha256:$synthetic_digest" --out json \
    < "$input" > "$out" 2> "$work/$label.err" || rc=$?
  case "$rc" in
    0) if [ -s "$out" ]; then printf 'accept\n'; else printf 'uncertain\n'; fi ;;
    1) printf 'reject\n' ;;
    *) printf 'uncertain\n' ;;
  esac
}

# One authored fixture, all the way from authored bytes to a projected plan.
# A rejection at either stage is a rejection before plan publication.
structural_verdict() {
  local fixture="$1" out="$2" json verdict
  json="$out.authored"
  verdict="$(authored_export "$fixture" "$json")"
  if [ "$verdict" != accept ]; then
    printf '%s\n' "$verdict"
    return
  fi
  schema_project "$json" "$out"
}

# ---------------------------------------------------------------------------
# Calibration.  Each instrument is proved to discriminate before any assertion
# relies on it, so neither an accepting nor a rejecting answer can be vacuous.
# ---------------------------------------------------------------------------

property self-test >/dev/null 2>&1 \
  || infra_stop 'the plan property instrument failed its own calibration'

# The logical-reference GREEN matcher is gated by successor projection.  Feed a
# synthetic conforming observation through that exact matcher now, while the
# seam may still be absent, and prove independently wrong names and references
# are refused.  A later GREEN can therefore neither be lost to serialization
# whitespace nor credited to a matcher that never accepts its valid case.
printf '%s\n' \
  '{"spec":{"secrets":[{"name":"broker-token","reference":"agent-lab.secret/broker-token"}]}}' \
  > "$work/reference-calibration-valid.json" \
  || infra_stop 'the declared-reference calibration input is unavailable'
printf '%s\n' \
  '{"spec":{"secrets":[{"name":"registry-pull","reference":"agent-lab.secret/broker-token"}]}}' \
  > "$work/reference-calibration-wrong-name.json" \
  || infra_stop 'the declared-reference wrong-name neighbor is unavailable'
printf '%s\n' \
  '{"spec":{"secrets":[{"name":"broker-token","reference":"agent-lab.secret/registry-pull"}]}}' \
  > "$work/reference-calibration-wrong-reference.json" \
  || infra_stop 'the declared-reference wrong-reference neighbor is unavailable'
matches_broker_reference "$work/reference-calibration-valid.json" >/dev/null 2>&1 \
  || infra_stop 'the declared-reference matcher refused a synthetic conforming observation'
reference_calibration_rc=0
matches_broker_reference "$work/reference-calibration-wrong-name.json" >/dev/null 2>&1 \
  || reference_calibration_rc=$?
[ "$reference_calibration_rc" -eq 1 ] \
  || infra_stop 'the declared-reference matcher accepted a wrong-name neighbor'
reference_calibration_rc=0
matches_broker_reference "$work/reference-calibration-wrong-reference.json" >/dev/null 2>&1 \
  || reference_calibration_rc=$?
[ "$reference_calibration_rc" -eq 1 ] \
  || infra_stop 'the declared-reference matcher accepted a wrong-reference neighbor'

calibration="$work/cue-calibration"
mkdir -p "$calibration/cue.mod" || infra_stop 'CUE calibration root unavailable'
printf 'module: "agent-lab.local/g1-calibration"\nlanguage: version: "v0.9.0"\n' \
  > "$calibration/cue.mod/module.cue" || infra_stop 'CUE calibration module unavailable'
cat > "$calibration/schema.cue" <<'CUE' || infra_stop 'CUE calibration schema unavailable'
package calibration

#Closed: close({name: string, count: int})

value: #Closed
CUE
printf '{"name":"ok","count":1}\n' > "$work/calibration-good.json" \
  || infra_stop 'CUE calibration input unavailable'
printf '{"name":"ok","count":1,"unexpected":true}\n' > "$work/calibration-bad.json" \
  || infra_stop 'CUE calibration input unavailable'
calibration_rc=0
timeout "$command_timeout" "${cue_env[@]}" python3 -I -B "$cue_tool" \
  -C "$calibration" export -E schema.cue -l 'value:' 'json:' - -e value --out json \
  < "$work/calibration-good.json" > "$work/calibration-good.out" 2>/dev/null || calibration_rc=$?
[ "$calibration_rc" -eq 0 ] && [ -s "$work/calibration-good.out" ] \
  || infra_stop 'the pinned CUE boundary could not accept a valid calibration value'
calibration_rc=0
timeout "$command_timeout" "${cue_env[@]}" python3 -I -B "$cue_tool" \
  -C "$calibration" export -E schema.cue -l 'value:' 'json:' - -e value --out json \
  < "$work/calibration-bad.json" > /dev/null 2>/dev/null || calibration_rc=$?
[ "$calibration_rc" -eq 1 ] \
  || infra_stop 'the pinned CUE boundary did not refuse an unknown field; structural verdicts would be vacuous'

cedar_calibration="$work/cedar-calibration"
mkdir -p "$cedar_calibration" || infra_stop 'Cedar calibration root unavailable'
cat > "$cedar_calibration/schema.cedarschema" <<'CEDAR' || infra_stop 'Cedar calibration schema unavailable'
namespace Calibration {
    entity Principal = {bound: Bool};
    entity Resource = {bound: Bool};
    action "probe" appliesTo {
        principal: [Principal],
        resource: [Resource],
        context: {bound: Bool},
    };
}
CEDAR
cat > "$cedar_calibration/policy.cedar" <<'CEDAR' || infra_stop 'Cedar calibration policy unavailable'
@id("g1-calibration")
permit (
  principal == Calibration::Principal::"probe",
  action == Calibration::Action::"probe",
  resource is Calibration::Resource
)
when { context.bound && principal.bound && resource.bound };
CEDAR
cat > "$cedar_calibration/entities.json" <<'JSON' || infra_stop 'Cedar calibration entities unavailable'
[
  {"uid": {"type": "Calibration::Principal", "id": "probe"}, "attrs": {"bound": true}, "parents": []},
  {"uid": {"type": "Calibration::Resource", "id": "probe"}, "attrs": {"bound": true}, "parents": []}
]
JSON
cedar_request() {
  printf '{"principal":"Calibration::Principal::\\"probe\\"","action":"Calibration::Action::\\"probe\\"","resource":"Calibration::Resource::\\"probe\\"","context":{"bound":%s}}\n' \
    "$1" > "$cedar_calibration/request-$1.json"
}
cedar_request true || infra_stop 'Cedar calibration request unavailable'
cedar_request false || infra_stop 'Cedar calibration request unavailable'

cedar_run() {
  local label="$1"
  shift
  capture "$label" "${lab_env[@]}" python3 -I -B "$cedar_tool" "$@"
}

cedar_run cedar-validate --error-format json validate --deny-warnings \
  --validation-mode strict --schema "$cedar_calibration/schema.cedarschema" \
  --policies "$cedar_calibration/policy.cedar"
[ "$CAPTURE_RC" -eq 0 ] \
  || infra_stop 'the pinned Cedar boundary could not validate a calibration policy set'
cedar_run cedar-allow --error-format json authorize --request-validation true \
  --schema "$cedar_calibration/schema.cedarschema" \
  --policies "$cedar_calibration/policy.cedar" \
  --entities "$cedar_calibration/entities.json" \
  --request-json "$cedar_calibration/request-true.json"
[ "$CAPTURE_RC" -eq 0 ] && grep -Fqx 'ALLOW' "$CAPTURE_OUT" \
  || infra_stop 'the pinned Cedar boundary could not reach a calibration permit'
cedar_run cedar-deny --error-format json authorize --request-validation true \
  --schema "$cedar_calibration/schema.cedarschema" \
  --policies "$cedar_calibration/policy.cedar" \
  --entities "$cedar_calibration/entities.json" \
  --request-json "$cedar_calibration/request-false.json"
[ "$CAPTURE_RC" -eq 2 ] && grep -Fqx 'DENY' "$CAPTURE_OUT" \
  || infra_stop 'the pinned Cedar boundary did not deny an unsatisfied calibration request; denial evidence would be vacuous'

# The secret canary instrument: prove the search finds the value when it is
# present, so "the product never echoed it" is a real observation.
printf 'prefix %s suffix\n' "$canary" > "$work/canary-present"
printf 'prefix redacted suffix\n' > "$work/canary-absent"
if ! grep -Fq "$canary" "$work/canary-present" \
   || grep -Fq "$canary" "$work/canary-absent"; then
  infra_stop 'the synthetic secret canary instrument is not calibrated'
fi
if ! grep -Fq "$canary" "$fixtures/inline-secret-value.cue"; then
  infra_stop 'the inline-secret fixture does not carry the synthetic canary'
fi

# The effect canary: a deny-by-default recorder shadowing the effect tools a
# fail-closed authority decision must never reach.  Its reach is the product
# process itself, which is exactly where an acquisition, credential, lifecycle,
# or Docker effect would be started.
deny_dir="$work/deny/bin"
effect_log="$work/effect.log"
mkdir -p "$deny_dir" || infra_stop 'effect canary directory could not be created'
: > "$effect_log"
cat > "$work/deny/record" <<EOF || infra_stop 'effect canary recorder could not be written'
#!/bin/sh
printf '%s\n' "\${0##*/}" >> '$effect_log'
exit 97
EOF
chmod 0755 "$work/deny/record" || infra_stop 'effect canary recorder could not be armed'
for effect_tool in docker docker-compose podman nerdctl ctr crictl kubectl helm \
                   systemctl curl wget nc ncat socat ssh scp rsync git pip pip3 npm; do
  ln -s "$work/deny/record" "$deny_dir/$effect_tool" \
    || infra_stop 'effect canary could not shadow an effect tool'
done
if ! PATH="$deny_dir:/usr/bin:/bin" timeout "$command_timeout" docker calibration >/dev/null 2>&1; then
  :
fi
[ -s "$effect_log" ] || infra_stop 'the effect canary did not record a real invocation'
: > "$effect_log"

probe seam-check seam
[ "$CAPTURE_RC" -eq 0 ] \
  || infra_stop 'the isolated product import pattern is unavailable in this checkout'
if [ "$(property get "$CAPTURE_OUT" present)" = 'true' ]; then
  seam_present=1
else
  seam_missing="$(property get "$CAPTURE_OUT" missing)"
  note seam "successor plan-authority seam is absent: $seam_missing"
fi

# ---------------------------------------------------------------------------
# Shared observations.
# ---------------------------------------------------------------------------

legacy_ok=1
legacy_plan="$work/legacy-plan.json"

observe_legacy() {
  # The unchanged v0alpha1 path, twice, so byte stability is observed rather
  # than assumed.
  capture legacy-check-1 "${lab_env[@]}" python3 -I -B "$experiment_tool" \
    check-directory "$legacy_fixture"
  [ "$CAPTURE_RC" -eq 0 ] && [ ! -s "$CAPTURE_ERR" ] || legacy_ok=0
  cp "$CAPTURE_OUT" "$work/legacy-check-first" 2>/dev/null || legacy_ok=0
  capture legacy-check-2 "${lab_env[@]}" python3 -I -B "$experiment_tool" \
    check-directory "$legacy_fixture"
  [ "$CAPTURE_RC" -eq 0 ] || legacy_ok=0
  cmp -s "$work/legacy-check-first" "$CAPTURE_OUT" || legacy_ok=0
  property extract "$work/legacy-check-first" plan "$legacy_plan" >/dev/null 2>&1 || legacy_ok=0
  [ "$(property get "$legacy_plan" apiVersion 2>/dev/null)" = 'agent-lab.request/v0alpha1' ] || legacy_ok=0
  [ "$(property get "$legacy_plan" contract.version 2>/dev/null)" = 'v0alpha1' ] || legacy_ok=0

  capture legacy-authorize-1 "${lab_env[@]}" python3 -I -B "$experiment_tool" \
    authorize-directory "$legacy_fixture"
  [ "$CAPTURE_RC" -eq 0 ] && [ ! -s "$CAPTURE_ERR" ] || legacy_ok=0
  cp "$CAPTURE_OUT" "$work/legacy-decision" 2>/dev/null || legacy_ok=0
  [ "$(property get "$work/legacy-decision" verdict 2>/dev/null)" = 'permit' ] || legacy_ok=0
  [ "$(property get "$work/legacy-decision" apiVersion 2>/dev/null)" \
    = 'agent-lab.authorization/v0alpha1' ] || legacy_ok=0
  [ "$(property get "$work/legacy-decision" binding.planDigest 2>/dev/null)" \
    = "$(property get "$work/legacy-check-first" digest 2>/dev/null)" ] || legacy_ok=0
  capture legacy-authorize-2 "${lab_env[@]}" python3 -I -B "$experiment_tool" \
    authorize-directory "$legacy_fixture"
  [ "$CAPTURE_RC" -eq 0 ] || legacy_ok=0
  cmp -s "$work/legacy-decision" "$CAPTURE_OUT" || legacy_ok=0
}

observe_legacy

# ---------------------------------------------------------------------------
# The private-copy policy instrument.
#
# A verdict that only ever comes back as the value the suite expected proves
# nothing about where it came from.  This instrument answers "does the decision
# follow the effective Cedar policy" by asking the product the same question
# under disposable copies of this checkout that differ in exactly one file.
#
# Each copy is a repository root of its own: product sources, contract roots,
# and authorization roots are real copies inside the suite's private mktemp
# tree, everything else is a symlink to the unchanged checkout, and nothing
# tracked is ever opened for writing.  The mutation is a blanket forbid appended
# to one lab install policy -- it needs to know nothing about what that policy
# says, because a Cedar forbid overrides every permit.
#
# Three copies are prepared, and each mutation is isolated in its own:
#
#   copy-pristine          unchanged, and the reference both comparisons are
#                          made against;
#   copy-legacy-forbid     pristine except for the v0alpha1 lab install policy,
#                          used only to calibrate the instrument on the
#                          unchanged legacy path, which is already known to
#                          reach a permit; and
#   copy-successor-forbid  pristine except for the v0alpha2 lab install policy,
#                          used only for the successor comparison.
#
# Keeping the two mutations apart is what lets the successor comparison mean
# what it claims.  A single copy carrying both would leave the successor answer
# explainable by the legacy difference, so a product reacting to a policy it has
# no business reading could still produce the expected deny.  The successor copy
# therefore carries no legacy mutation at all, and the paths at which it differs
# from pristine are enumerated rather than assumed.
#
# Calibration runs immediately below, on the unchanged v0alpha1 path: the
# pristine copy must reproduce the real checkout's decision byte for byte, so
# the copy is proved to exercise the real product path rather than a stub, and
# the legacy-forbid copy must lose that permit, so the mutation is proved to be
# observable at all.
# ---------------------------------------------------------------------------

private_copy() {
  # A repository root that behaves like this checkout and can be edited freely.
  local root="$1" entry name
  mkdir -p "$root" || return 1
  for entry in "$repo_root"/* "$repo_root/.cache"; do
    [ -e "$entry" ] || continue
    name="${entry##*/}"
    case "$name" in
      scripts | contracts | authorization) continue ;;
    esac
    ln -s "$entry" "$root/$name" || return 1
  done
  # The three roots a product decision is drawn from are real, writable copies.
  cp -R "$repo_root/scripts" "$root/scripts" || return 1
  cp -R "$repo_root/contracts" "$root/contracts" || return 1
  cp -R "$repo_root/authorization" "$root/authorization" || return 1
  return 0
}

append_forbid() {
  local file="$1"
  [ -f "$file" ] || return 1
  printf '\n@id("g1PrivateCopyProbe")\nforbid (principal, action, resource);\n' >> "$file"
}

private_copy_tree_record() {
  # Canonical evidence for a complete private root.  Every entry contributes its
  # relative path, type, mode, symlink target, or regular-file byte digest.
  local root="$1" record="$2"
  python3 -I -B - "$root" "$record" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import stat
import sys

root = Path(sys.argv[1])
record = Path(sys.argv[2])
entries = []

def file_digest(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def visit(directory):
    for path in sorted(directory.iterdir(), key=lambda item: os.fsencode(item.name)):
        status = path.lstat()
        entry = {
            "mode": f"{stat.S_IMODE(status.st_mode):04o}",
            "path": path.relative_to(root).as_posix(),
        }
        if stat.S_ISLNK(status.st_mode):
            entry.update(type="symlink", target=os.readlink(path))
        elif stat.S_ISREG(status.st_mode):
            entry.update(type="file", sha256=file_digest(path))
        elif stat.S_ISDIR(status.st_mode):
            entry.update(type="directory")
        else:
            raise SystemExit("unsupported private-copy entry type")
        entries.append(entry)
        if stat.S_ISDIR(status.st_mode):
            visit(path)

visit(root)
document = {
    "entries": sorted(entries, key=lambda entry: entry["path"]),
    "root_mode": f"{stat.S_IMODE(root.lstat().st_mode):04o}",
    "schema_version": 1,
}
record.write_text(
    json.dumps(document, ensure_ascii=True, separators=(",", ":"), sort_keys=True) + "\n",
    encoding="ascii",
)
PY
}

private_copy_changed_paths() {
  # Canonical JSON array of every path whose type, mode, target, or bytes differ.
  local before="$1" after="$2"
  python3 -I -B - "$before" "$after" <<'PY'
import json
from pathlib import Path
import sys

before = json.loads(Path(sys.argv[1]).read_text(encoding="ascii"))
after = json.loads(Path(sys.argv[2]).read_text(encoding="ascii"))
left = {entry["path"]: entry for entry in before["entries"]}
right = {entry["path"]: entry for entry in after["entries"]}
changed = []
if before["root_mode"] != after["root_mode"]:
    changed.append(".")
for path in sorted(set(left) | set(right)):
    if left.get(path) != right.get(path):
        changed.append(path)
print(json.dumps(changed, ensure_ascii=True, separators=(",", ":")))
PY
}

private_sha256() {
  local digest
  read -r digest _ < <(sha256sum -- "$1") || return 1
  printf '%s\n' "$digest"
}

private_input_sha256() {
  local input="$1" label="$2" record
  if [ -f "$input" ]; then
    private_sha256 "$input"
  elif [ -d "$input" ]; then
    record="$work/private-input-$label.json"
    private_copy_tree_record "$input" "$record" || return 1
    private_sha256 "$record"
  else
    return 1
  fi
}

private_tree_file_sha256() {
  local record="$1" relative="$2"
  python3 -I -B - "$record" "$relative" <<'PY'
import json
from pathlib import Path
import re
import sys

document = json.loads(Path(sys.argv[1]).read_text(encoding="ascii"))
matches = [entry for entry in document["entries"] if entry["path"] == sys.argv[2]]
if len(matches) != 1 or matches[0].get("type") != "file":
    raise SystemExit(1)
digest = matches[0].get("sha256", "")
if re.fullmatch(r"[0-9a-f]{64}", digest) is None:
    raise SystemExit(1)
print(digest)
PY
}

private_copy_comparison_guard() {
  # Bind root roles, intended variable, and held input.  Swapped roots or an
  # undeclared comparison cannot reach evidence production.
  local comparison="$1" before_label="$2" before_root="$3"
  local after_label="$4" after_root="$5" intended="$6"
  local input_label="$7" held_input="$8"
  private_evidence_reason=''
  case "$comparison" in
    legacy)
      if [ "$before_label" != pristine ] || [ "$before_root" != "$private_pristine" ] \
         || [ "$after_label" != legacy-forbid ] || [ "$after_root" != "$private_legacy_forbid" ] \
         || [ "$intended" != "$legacy_policy" ] || [ "$input_label" != legacy-directory ] \
         || [ "$held_input" != "$legacy_fixture" ]; then
        private_evidence_reason='the legacy comparison has swapped roots, variable, or input'
        return 1
      fi
      ;;
    successor)
      if [ "$before_label" != pristine ] || [ "$before_root" != "$private_pristine" ] \
         || [ "$after_label" != successor-forbid ] || [ "$after_root" != "$private_successor_forbid" ] \
         || [ "$intended" != "$successor_policy" ] || [ "$input_label" != projected-valid-plan ] \
         || [ "$held_input" != "$work/plan-valid.json" ]; then
        private_evidence_reason='the successor comparison has swapped roots, variable, or input'
        return 1
      fi
      ;;
    *)
      private_evidence_reason='the comparison has no single declared variable'
      return 1
      ;;
  esac
}

private_copy_comparison_begin() {
  # Seal canonical pre-evaluation records for both roots and the shared input.
  local comparison="$1" before_label="$2" before_root="$3"
  local after_label="$4" after_root="$5" intended="$6"
  local input_label="$7" held_input="$8" base input_hash
  if ! private_copy_comparison_guard "$@"; then
    return 1
  fi
  base="$work/private-evidence-$comparison"
  if ! private_copy_tree_record "$before_root" "$base.before-root.before-evaluation.json" \
     || ! private_copy_tree_record "$after_root" "$base.after-root.before-evaluation.json"; then
    private_evidence_reason='canonical pre-evaluation tree records could not be produced'
    return 1
  fi
  input_hash="$(private_input_sha256 "$held_input" "$comparison-before" 2>/dev/null || :)"
  if [[ ! "$input_hash" =~ ^[0-9a-f]{64}$ ]]; then
    private_evidence_reason='the pre-evaluation input SHA-256 hash is omitted'
    return 1
  fi
  printf '%s\n' "$input_hash" > "$base.input.before-evaluation.sha256" || {
    private_evidence_reason='the pre-evaluation input hash could not be sealed'
    return 1
  }
}

private_copy_comparison_finish() {
  # Re-record both roots and the shared input after evaluation, then emit one
  # canonical record only if the intended policy is the sole cross-root change
  # both before and after evaluation and no root or input changed during it.
  local comparison="$1" before_label="$2" before_root="$3"
  local after_label="$4" after_root="$5" intended="$6"
  local input_label="$7" held_input="$8" base before_pre after_pre before_post after_post
  local before_tree_pre before_tree_post after_tree_pre after_tree_post
  local before_policy_pre before_policy_post after_policy_pre after_policy_post
  local input_pre input_post changes_pre changes_post expected evidence
  if ! private_copy_comparison_guard "$@"; then
    return 1
  fi

  base="$work/private-evidence-$comparison"
  before_pre="$base.before-root.before-evaluation.json"
  after_pre="$base.after-root.before-evaluation.json"
  before_post="$base.before-root.after-evaluation.json"
  after_post="$base.after-root.after-evaluation.json"
  if [ ! -s "$before_pre" ] || [ ! -s "$after_pre" ] \
     || [ ! -s "$base.input.before-evaluation.sha256" ]; then
    private_evidence_reason='required pre-evaluation evidence is omitted'
    return 1
  fi
  if ! private_copy_tree_record "$before_root" "$before_post" \
     || ! private_copy_tree_record "$after_root" "$after_post"; then
    private_evidence_reason='canonical post-evaluation tree records could not be produced'
    return 1
  fi
  before_tree_pre="$(private_sha256 "$before_pre" 2>/dev/null || :)"
  before_tree_post="$(private_sha256 "$before_post" 2>/dev/null || :)"
  after_tree_pre="$(private_sha256 "$after_pre" 2>/dev/null || :)"
  after_tree_post="$(private_sha256 "$after_post" 2>/dev/null || :)"
  before_policy_pre="$(private_tree_file_sha256 "$before_pre" "$intended" 2>/dev/null || :)"
  before_policy_post="$(private_tree_file_sha256 "$before_post" "$intended" 2>/dev/null || :)"
  after_policy_pre="$(private_tree_file_sha256 "$after_pre" "$intended" 2>/dev/null || :)"
  after_policy_post="$(private_tree_file_sha256 "$after_post" "$intended" 2>/dev/null || :)"
  input_pre="$(< "$base.input.before-evaluation.sha256")"
  input_post="$(private_input_sha256 "$held_input" "$comparison-after" 2>/dev/null || :)"
  changes_pre="$(private_copy_changed_paths "$before_pre" "$after_pre" 2>/dev/null || :)"
  changes_post="$(private_copy_changed_paths "$before_post" "$after_post" 2>/dev/null || :)"
  for digest in "$before_tree_pre" "$before_tree_post" "$after_tree_pre" "$after_tree_post" \
                "$before_policy_pre" "$before_policy_post" "$after_policy_pre" \
                "$after_policy_post" "$input_pre" "$input_post"; do
    if [[ ! "$digest" =~ ^[0-9a-f]{64}$ ]]; then
      private_evidence_reason='the comparison omitted a required canonical SHA-256 hash'
      return 1
    fi
  done
  if [ "$before_tree_pre" != "$before_tree_post" ] \
     || [ "$after_tree_pre" != "$after_tree_post" ] \
     || [ "$before_policy_pre" != "$before_policy_post" ] \
     || [ "$after_policy_pre" != "$after_policy_post" ]; then
    private_evidence_reason='a private root changed during comparison evaluation'
    return 1
  fi
  if [ "$input_pre" != "$input_post" ]; then
    private_evidence_reason='the held comparison input changed during evaluation'
    return 1
  fi
  if [ "$before_tree_pre" = "$after_tree_pre" ] \
     || [ "$before_policy_pre" = "$after_policy_pre" ]; then
    private_evidence_reason='the declared variable has no unambiguous before/after change'
    return 1
  fi
  expected="[\"$intended\"]"
  if [ "$changes_pre" != "$expected" ] || [ "$changes_post" != "$expected" ]; then
    private_evidence_reason="the comparison changed unrelated or multiple paths ($changes_pre -> $changes_post)"
    return 1
  fi

  evidence="$base.json"
  printf '{"after_input_sha256":"%s","after_policy_sha256":"%s","after_root":"%s","after_root_after_evaluation_tree_sha256":"%s","after_root_before_evaluation_tree_sha256":"%s","before_input_sha256":"%s","before_policy_sha256":"%s","before_root":"%s","before_root_after_evaluation_tree_sha256":"%s","before_root_before_evaluation_tree_sha256":"%s","changed_paths_after":%s,"changed_paths_before":%s,"comparison":"%s","held_input":"%s","intended_variable":"%s","schema_version":1,"unrelated_paths":[]}\n' \
    "$input_post" "$after_policy_post" "$after_label" "$after_tree_post" "$after_tree_pre" \
    "$input_pre" "$before_policy_post" "$before_label" "$before_tree_post" "$before_tree_pre" \
    "$changes_post" "$changes_pre" "$comparison" "$input_label" "$intended" \
    > "$evidence" || {
      private_evidence_reason='the canonical mutation evidence record could not be emitted'
      return 1
    }
  note private-copy-evidence "$(< "$evidence")"
}

calibrate_private_copy() {
  if ! private_copy_comparison_begin legacy \
       pristine "$private_pristine" legacy-forbid "$private_legacy_forbid" \
       "$legacy_policy" legacy-directory "$legacy_fixture"; then
    private_copy_reason="the legacy-forbid pre-evidence is not single-variable: $private_evidence_reason"
    return
  fi
  capture private-pristine-legacy "${lab_env[@]}" python3 -I -B \
    "$private_pristine/scripts/experiment.py" authorize-directory "$legacy_fixture"
  if [ "$CAPTURE_RC" -ne 0 ] || ! cmp -s "$work/legacy-decision" "$CAPTURE_OUT"; then
    private_copy_reason='a pristine private copy did not reproduce the unchanged authorization decision'
    return
  fi
  # The calibration copy differs from pristine in exactly the v0alpha1 lab
  # install policy, so the permit it loses below is attributable to that policy
  # and to nothing else the copy carries.
  capture private-forbid-legacy "${lab_env[@]}" python3 -I -B \
    "$private_legacy_forbid/scripts/experiment.py" authorize-directory "$legacy_fixture"
  if ! private_copy_comparison_finish legacy \
       pristine "$private_pristine" legacy-forbid "$private_legacy_forbid" \
       "$legacy_policy" legacy-directory "$legacy_fixture"; then
    private_copy_reason="the legacy-forbid evidence is not single-variable: $private_evidence_reason"
    return
  fi
  if [ "$(property get "$CAPTURE_OUT" verdict 2>/dev/null)" != 'deny' ]; then
    private_copy_reason='a legacy-forbidding private copy still reached the unchanged authorization permit'
    return
  fi
  private_copy_ok=1
  private_copy_reason=''
}

private_pristine="$work/copy-pristine"
private_legacy_forbid="$work/copy-legacy-forbid"
private_successor_forbid="$work/copy-successor-forbid"
if ! private_copy "$private_pristine" \
   || ! private_copy "$private_legacy_forbid" \
   || ! private_copy "$private_successor_forbid" \
   || ! append_forbid "$private_legacy_forbid/$legacy_policy"; then
  private_copy_reason='a disposable private copy of this checkout could not be prepared'
else
  # The successor policy may not exist yet.  Its absence is an assertion result,
  # never a calibration fault, so the instrument is proved on v0alpha1 either
  # way -- and the successor mutation is applied to a copy of its own, so that
  # proof never varies anything the successor comparison depends on.
  if [ -f "$private_successor_forbid/$successor_policy" ] \
     && append_forbid "$private_successor_forbid/$successor_policy"; then
    successor_policy_varied=1
  fi
  calibrate_private_copy
fi
if [ "$private_copy_ok" -ne 1 ]; then
  # An instrument that cannot be calibrated while the unchanged path is healthy
  # is a harness fault.  If that path is itself unhealthy, the legacy assertion
  # below is the one that says so, and this stays an assertion result.
  if [ "$legacy_ok" -eq 1 ]; then
    infra_stop "the private-copy policy instrument is not calibrated: $private_copy_reason"
  fi
  note private-copy "$private_copy_reason"
fi

# Every successor fixture is driven once, here, so each scenario reads the same
# observations and no scenario can be satisfied by a differently phrased run.
declare -A fixture_verdict=()
successor_fixtures=(
  valid valid-reordered inline-secret-value host-secret-path unknown-field
  grant-undeclared grant-duplicate grant-host-path grant-selectable
  authority-absent authority-partial
)
for fixture_name in "${successor_fixtures[@]}"; do
  fixture_verdict["$fixture_name"]="$(
    structural_verdict "$fixtures/$fixture_name.cue" "$work/plan-$fixture_name.json"
  )"
done

structural_is() { [ "${fixture_verdict[$1]:-absent}" = "$2" ]; }

# ---------------------------------------------------------------------------
# WF-PLAN-LEGACY-INSPECTABLE -- corroborates SEC-PLAN-EXECUTABLE
#
# The positive control for the whole suite: the existing verified v0alpha1 path
# still produces readable, byte-stable evidence on unchanged product.  If this
# ever fails, a successor failure below is not evidence about the successor.
# ---------------------------------------------------------------------------

scenario_legacy_inspectable() {
  local id='WF-PLAN-LEGACY-INSPECTABLE'
  local text='verified v0alpha1 evidence stays readable and byte-stable on the unchanged legacy path'
  if [ "$legacy_ok" -eq 1 ]; then
    pass "$id" "$text"
  else
    note "$id" 'the unchanged v0alpha1 evidence path did not reproduce'
    fail "$id" "$text"
  fi
}

# ---------------------------------------------------------------------------
# SEC-PLAN-EXECUTABLE -- contract
# ---------------------------------------------------------------------------

classify_of() {
  # Prints the classification the product returned for one plan document, or a
  # stable placeholder describing why there is none.
  local label="$1" plan="$2"
  probe "classify-$label" classify "$plan"
  if [ "$CAPTURE_RC" -ne 0 ]; then
    printf 'probe-failed\n'
    return
  fi
  if [ "$(property get "$CAPTURE_OUT" ok)" != 'true' ]; then
    printf 'seam-absent\n'
    return
  fi
  if [ "$(property get "$CAPTURE_OUT" verdict)" != 'returned' ]; then
    printf 'raised\n'
    return
  fi
  if [ "$(property get "$CAPTURE_OUT" input_unchanged)" != 'true' ]; then
    printf 'impure\n'
    return
  fi
  property get "$CAPTURE_OUT" classification
}

scenario_plan_executable() {
  local id='SEC-PLAN-EXECUTABLE'
  local text='v0alpha1 remains inspectable but non-executable and v0alpha2 requires complete authority'
  local ok=1 eligible incomplete non_executable mutant field derived
  if [ "$seam_present" -ne 1 ]; then
    note "$id" "successor execution classification is absent: $seam_missing"
    fail "$id" "$text"
    return
  fi
  probe constants constants
  if [ "$CAPTURE_RC" -ne 0 ] || [ "$(property get "$CAPTURE_OUT" ok)" != 'true' ]; then
    note "$id" 'the successor execution classification constants are unavailable'
    fail "$id" "$text"
    return
  fi
  eligible="$(property get "$CAPTURE_OUT" eligible)"
  incomplete="$(property get "$CAPTURE_OUT" incomplete)"
  non_executable="$(property get "$CAPTURE_OUT" non_executable)"
  # Three classifications that are actually distinct, or the fail-closed
  # distinction below would be unobservable.
  if [ -z "$eligible" ] || [ -z "$incomplete" ] || [ -z "$non_executable" ] \
     || [ "$eligible" = "$incomplete" ] || [ "$eligible" = "$non_executable" ] \
     || [ "$incomplete" = "$non_executable" ]; then
    note "$id" 'the execution classifications are not three distinct values'
    ok=0
  fi

  # Legacy evidence: readable, and explicitly not executable.
  [ "$legacy_ok" -eq 1 ] || ok=0
  if [ "$(classify_of legacy "$legacy_plan")" != "$non_executable" ]; then
    note "$id" 'a verified v0alpha1 plan was not classified non-executable'
    ok=0
  fi

  # Complete successor authority: eligible.  Without this the whole scenario
  # would be satisfied by an implementation that classifies everything as
  # non-executable.
  if structural_is valid accept; then
    if [ "$(classify_of valid "$work/plan-valid.json")" != "$eligible" ]; then
      note "$id" 'a complete v0alpha2 plan was not classified executable-eligible'
      ok=0
    fi
    if [ "$(classify_of valid-again "$work/plan-valid.json")" != "$eligible" ]; then
      note "$id" 'the execution classification is not deterministic'
      ok=0
    fi
  else
    note "$id" "the complete successor fixture was not projected (${fixture_verdict[valid]:-absent})"
    ok=0
  fi

  # A manifest that declares no authority must be projected without one -- by the
  # product's own derivation as well as by the pinned CUE.  The plan property
  # boundary refuses a synthesized or defaulted authority block on each of them,
  # before and separately from whatever the product then classifies, so an
  # implementation cannot reach a classification by inventing the field first.
  #
  # The plan the product itself returned is then the plan that is classified.  A
  # derivation helper that quietly completes the authority block would otherwise
  # be invisible here: the pinned CUE projection would stay correct, and the
  # classification would be read off a document the product never produced.
  if structural_is authority-absent accept; then
    if ! property plan-shape "$work/plan-authority-absent.json" absent >/dev/null 2>&1; then
      note "$id" 'the authority-absent projection did not keep declared authority absent'
      ok=0
    fi
    derived="$work/derived-authority-absent.json"
    probe expected-authority-absent expected-plan \
      "$work/plan-authority-absent.json.authored" "$synthetic_digest"
    if [ "$CAPTURE_RC" -ne 0 ] \
       || [ "$(property get "$CAPTURE_OUT" ok 2>/dev/null)" != 'true' ] \
       || [ "$(property get "$CAPTURE_OUT" verdict 2>/dev/null)" != 'accept' ]; then
      note "$id" 'the product derivation returned no plan for the authority-absent manifest'
      ok=0
    elif ! property extract "$CAPTURE_OUT" plan "$derived" >/dev/null 2>&1; then
      note "$id" 'the product-returned authority-absent plan could not be read'
      ok=0
    else
      if ! property plan-shape "$derived" absent >/dev/null 2>&1; then
        note "$id" 'the product derivation synthesized authority the manifest never declared'
        ok=0
      fi
      if [ "$(classify_of derived-authority-absent "$derived")" != "$incomplete" ]; then
        note "$id" 'the product-returned authority-absent plan was not classified authority-incomplete'
        ok=0
      fi
    fi
  fi

  # A partially bound manifest must also be derived by the product rather than
  # classified only from the independent CUE projection.  Exact structural
  # equality preserves the intentionally incomplete authority binding: a
  # derivation that fills the missing declared reference fails before its own
  # returned plan is classified.
  if structural_is authority-partial accept; then
    derived="$work/derived-authority-partial.json"
    probe expected-authority-partial expected-plan \
      "$work/plan-authority-partial.json.authored" "$synthetic_digest"
    if [ "$CAPTURE_RC" -ne 0 ] \
       || [ "$(property get "$CAPTURE_OUT" ok 2>/dev/null)" != 'true' ] \
       || [ "$(property get "$CAPTURE_OUT" verdict 2>/dev/null)" != 'accept' ]; then
      note "$id" 'the product derivation returned no plan for the authority-partial manifest'
      ok=0
    elif ! property extract "$CAPTURE_OUT" plan "$derived" >/dev/null 2>&1; then
      note "$id" 'the product-returned authority-partial plan could not be read'
      ok=0
    else
      if ! property same "$derived" "$work/plan-authority-partial.json" >/dev/null 2>&1; then
        note "$id" 'the product derivation did not preserve the exact partial authority binding'
        ok=0
      fi
      if [ "$(classify_of derived-authority-partial "$derived")" != "$incomplete" ]; then
        note "$id" 'the product-returned authority-partial plan was not classified authority-incomplete'
        ok=0
      fi
    fi
  fi

  # Declared authority absent, and declared authority present but not bound to
  # every declared reference: both are the known denial, never eligibility.
  for fixture_name in authority-absent authority-partial; do
    if structural_is "$fixture_name" accept; then
      if [ "$(classify_of "$fixture_name" "$work/plan-$fixture_name.json")" != "$incomplete" ]; then
        note "$id" "$fixture_name was not classified authority-incomplete"
        ok=0
      fi
    else
      note "$id" "$fixture_name was not projected (${fixture_verdict[$fixture_name]:-absent})"
      ok=0
    fi
  done

  # Fail closed on every authority-bearing field, one at a time, against mutants
  # derived here rather than stored: a defaulted field can never be eligible.
  if structural_is valid accept; then
    for field in drop-authority drop-authority-principal drop-authority-assurance \
                 drop-authority-secrets; do
      mutant="$work/classify-mutant-$field.json"
      if ! property mutate "$work/plan-valid.json" "$field" "$mutant" >/dev/null 2>&1; then
        note "$id" "the $field mutant could not be derived"
        ok=0
        continue
      fi
      if [ "$(classify_of "$field" "$mutant")" = "$eligible" ]; then
        note "$id" "$field remained executable-eligible"
        ok=0
      fi
    done
  fi

  if [ "$ok" -eq 1 ]; then
    pass "$id" "$text"
  else
    fail "$id" "$text"
  fi
}

# ---------------------------------------------------------------------------
# REC-PLAN-AUTHORITY-DENIAL -- corroborates SEC-PLAN-EXECUTABLE
# ---------------------------------------------------------------------------

authorize_of() {
  # Prints "<verdict> <status>" for one plan, driven through the product's own
  # Cedar seam under one repository root, with the effect canary armed.
  local root="$1" label="$2" plan="$3"
  : > "$effect_log"
  capture "authorize-$label" env PATH="$deny_dir:/usr/bin:/bin" \
    LANG=C LC_ALL=C PYTHONDONTWRITEBYTECODE=1 "HOME=$work/home" "TMPDIR=$work/tmp" \
    "AGENT_LAB_CUE_TOOL_DIR=$cue_tool_dir" "AGENT_LAB_CEDAR_TOOL_DIR=$cedar_tool_dir" \
    python3 -I -B "$probe_tool" "$root" authorize "$plan" "$zero_digest"
  if [ "$CAPTURE_RC" -ne 0 ] || [ "$(property get "$CAPTURE_OUT" ok)" != 'true' ]; then
    printf 'unavailable -\n'
    return
  fi
  if [ "$(property get "$CAPTURE_OUT" verdict)" != 'decided' ]; then
    printf '%s -\n' "$(property get "$CAPTURE_OUT" verdict)"
    return
  fi
  if [ -s "$effect_log" ]; then
    printf 'effectful -\n'
    return
  fi
  printf '%s %s\n' \
    "$(property get "$CAPTURE_OUT" decision.verdict)" \
    "$(property get "$CAPTURE_OUT" status)"
}

scenario_authority_denial() {
  local id='REC-PLAN-AUTHORITY-DENIAL'
  local text='authority-incomplete v0alpha2 install authorization is a stable known denial before any effect'
  local ok=1 fixture_name forbidden pristine_answer successor_legacy_ok
  if [ "$seam_present" -ne 1 ]; then
    note "$id" "successor install authorization is absent: $seam_missing"
    fail "$id" "$text"
    return
  fi
  if [ ! -d "$successor_authorization" ]; then
    note "$id" 'the successor authorization root is absent'
    fail "$id" "$text"
    return
  fi

  # Cedar validation is asserted on its own terms, separately from any CUE
  # verdict: the successor policy set has to be strictly valid against the
  # successor schema before any decision drawn from it means anything.
  cedar_run successor-validate --error-format json validate --deny-warnings \
    --validation-mode strict \
    --schema "$successor_authorization/schema.cedarschema" \
    --policies "$successor_authorization/operator.cedar"
  if [ "$CAPTURE_RC" -ne 0 ]; then
    note "$id" 'the successor Cedar policy set is not strictly valid'
    ok=0
  fi

  # The positive control: complete declared authority reaches a permit, so a
  # deny below is a decision rather than a posture.
  if structural_is valid accept; then
    if [ "$(authorize_of "$repo_root" valid "$work/plan-valid.json")" != 'permit 0' ]; then
      note "$id" 'a complete v0alpha2 plan did not reach a permit'
      ok=0
    fi
  else
    note "$id" 'the complete successor fixture was not projected'
    ok=0
  fi

  # The known denial, twice, so stability is observed rather than assumed.
  for fixture_name in authority-absent authority-partial; do
    if structural_is "$fixture_name" accept; then
      if [ "$(authorize_of "$repo_root" "$fixture_name" "$work/plan-$fixture_name.json")" != 'deny 1' ] \
         || [ "$(authorize_of "$repo_root" "$fixture_name-again" "$work/plan-$fixture_name.json")" != 'deny 1' ]; then
        note "$id" "$fixture_name did not reach a stable known denial with no effect"
        ok=0
      fi
    else
      note "$id" "$fixture_name was not projected"
      ok=0
    fi
  done

  # The decision has to be drawn from the effective Cedar policy, not chosen from
  # the shape of the plan.  The same complete plan is put to the product twice,
  # under the pristine private copy and under the copy whose only difference is
  # the successor lab install policy.  The pristine copy has to reach the same
  # permit the real checkout reached, so the copy is proved to run the real
  # product path; the forbidding copy has to reach a deny instead.
  #
  # What that pair differs in is enumerated first rather than claimed.  The
  # calibration mutation lives in a third copy that is not used here, so the
  # successor copy carries no legacy-policy difference for a wrong product to
  # react to, and the successor deny cannot be explained by anything but the
  # successor policy.  Structural validation is untouched by this: both copies
  # carry the same successor contract root, and the plan handed over is the same
  # projected document in both runs.
  if [ "$private_copy_ok" -ne 1 ]; then
    note "$id" "the private-copy policy instrument is not calibrated: $private_copy_reason"
    ok=0
  elif [ "$successor_policy_varied" -ne 1 ]; then
    note "$id" 'the successor lab install policy could not be varied in a private copy'
    ok=0
  elif structural_is valid accept; then
    if ! private_copy_comparison_begin successor \
         pristine "$private_pristine" successor-forbid "$private_successor_forbid" \
         "$successor_policy" projected-valid-plan "$work/plan-valid.json"; then
      note "$id" "the successor-forbid pre-evidence is not single-variable: $private_evidence_reason"
      ok=0
    else
      pristine_answer="$(authorize_of "$private_pristine" private-valid "$work/plan-valid.json")"
      # The successor mutation is inert on the unchanged legacy path, so the
      # deny below is the successor policy taking effect rather than a copy that
      # refuses whatever it is asked.
      successor_legacy_ok=1
      capture successor-forbid-legacy "${lab_env[@]}" python3 -I -B \
        "$private_successor_forbid/scripts/experiment.py" \
        authorize-directory "$legacy_fixture"
      if [ "$CAPTURE_RC" -ne 0 ] || ! cmp -s "$work/legacy-decision" "$CAPTURE_OUT"; then
        successor_legacy_ok=0
      fi
      forbidden="$(authorize_of "$private_successor_forbid" forbidden-valid "$work/plan-valid.json")"
      if ! private_copy_comparison_finish successor \
           pristine "$private_pristine" successor-forbid "$private_successor_forbid" \
           "$successor_policy" projected-valid-plan "$work/plan-valid.json"; then
        note "$id" "the successor-forbid evidence is not single-variable: $private_evidence_reason"
        ok=0
      fi
      if [ "$pristine_answer" != 'permit 0' ]; then
        note "$id" 'a pristine private copy did not reproduce the successor permit'
        ok=0
      fi
      if [ "$successor_legacy_ok" -ne 1 ]; then
        note "$id" 'forbidding the successor policy changed the unchanged v0alpha1 decision'
        ok=0
      fi
      case "$forbidden" in
        'deny '*) ;;
        *)
          note "$id" "the successor decision did not follow the effective Cedar policy ($forbidden)"
          ok=0
          ;;
      esac
    fi
  fi

  # Authored policy input may subtract authority and may never add it.
  printf 'forbid (principal, action, resource) when { true };\n' \
    > "$work/authored-forbid.cedar"
  printf 'permit (principal, action, resource) when { true };\n' \
    > "$work/authored-permit.cedar"
  probe forbid-only-forbid forbid-only "$work/authored-forbid.cedar"
  if [ "$CAPTURE_RC" -ne 0 ] \
     || [ "$(property get "$CAPTURE_OUT" forbid_only 2>/dev/null)" != 'true' ]; then
    note "$id" 'an authored forbid-only policy was not accepted as forbid-only'
    ok=0
  fi
  probe forbid-only-permit forbid-only "$work/authored-permit.cedar"
  if [ "$CAPTURE_RC" -ne 0 ] \
     || [ "$(property get "$CAPTURE_OUT" forbid_only 2>/dev/null)" != 'false' ]; then
    note "$id" 'an authored policy that grants was not refused'
    ok=0
  fi

  if [ "$ok" -eq 1 ]; then
    pass "$id" "$text"
  else
    fail "$id" "$text"
  fi
}

# ---------------------------------------------------------------------------
# Shared refusal instrument.
#
# What the product's own successor entry points did with one authored manifest.
# A structural refusal by the pinned CUE says nothing about the product seam, so
# every manifest the contract refuses is put to the product as well, and a
# refusal only counts when the product also published no plan.
# ---------------------------------------------------------------------------

product_refuses() {
  # Prints "refused" when every named successor entry point refused this
  # manifest without returning a plan, or a short reason why it did not.
  local label="$1" manifest="$2" question verdict
  shift 2
  for question in "$@"; do
    probe "$question-$label" "$question" "$manifest" "$synthetic_digest"
    if [ "$CAPTURE_RC" -ne 0 ] \
       || [ "$(property get "$CAPTURE_OUT" ok 2>/dev/null)" != 'true' ]; then
      printf '%s-unavailable\n' "$question"
      return
    fi
    verdict="$(property get "$CAPTURE_OUT" verdict 2>/dev/null)"
    if [ "$verdict" != 'reject' ]; then
      printf '%s-%s\n' "$question" "${verdict:-unreadable}"
      return
    fi
    # A refusal that still hands back a plan is a publication, not a refusal.
    if property get "$CAPTURE_OUT" plan >/dev/null 2>&1; then
      printf '%s-published\n' "$question"
      return
    fi
  done
  printf 'refused\n'
}

# ---------------------------------------------------------------------------
# SEC-PLAN-INLINE-SECRET -- contract
# ---------------------------------------------------------------------------

scenario_inline_secret() {
  local id='SEC-PLAN-INLINE-SECRET'
  local text='the closed v0alpha2 authored schema rejects inline secret values and host secret paths before publication'
  local ok=1 fixture_name reason
  if [ ! -d "$successor_contract" ]; then
    note "$id" 'the successor contract root is absent'
    fail "$id" "$text"
    return
  fi
  for fixture_name in inline-secret-value host-secret-path unknown-field; do
    if ! structural_is "$fixture_name" reject; then
      note "$id" "$fixture_name was not refused (${fixture_verdict[$fixture_name]:-absent})"
      ok=0
    fi
    # A refusal before publication leaves no projected plan behind.
    if [ -s "$work/plan-$fixture_name.json" ]; then
      note "$id" "$fixture_name produced a projected plan despite refusal"
      ok=0
    fi
  done
  # The adjacent well-formed manifest is still accepted, so the refusals are
  # targeted rather than a closed door.
  if ! structural_is valid accept; then
    note "$id" "the adjacent valid manifest was not accepted (${fixture_verdict[valid]:-absent})"
    ok=0
  fi
  # Both product successor entry points agree with the structural verdict on
  # each refused manifest, and neither returns a plan.  Checking validation
  # alone would leave derivation free to accept an inline value, a host secret
  # path, or an unknown authored field that CUE and validation refused.
  if [ "$seam_present" -eq 1 ]; then
    for fixture_name in inline-secret-value host-secret-path unknown-field; do
      reason="$(product_refuses "$fixture_name" \
        "$work/plan-$fixture_name.json.authored" validate expected-plan)"
      if [ "$reason" != 'refused' ]; then
        note "$id" "both product successor seams did not refuse $fixture_name ($reason)"
        ok=0
      fi
    done
  else
    note "$id" "successor validation is absent: $seam_missing"
    ok=0
  fi
  if [ "$ok" -eq 1 ]; then
    pass "$id" "$text"
  else
    fail "$id" "$text"
  fi
}

# ---------------------------------------------------------------------------
# SEC-PLAN-SECRET-QUIET -- corroborates SEC-PLAN-INLINE-SECRET
# ---------------------------------------------------------------------------

scenario_secret_quiet() {
  local id='SEC-PLAN-SECRET-QUIET'
  local text='no synthetic inline secret value reaches any product diagnostic or evidence channel'
  local ok=1 channel question message
  if [ "$seam_present" -ne 1 ]; then
    note "$id" "successor validation is absent, so quietness is unproven: $seam_missing"
    fail "$id" "$text"
    return
  fi
  # Observe both product entry points independently.  CAPTURE_OUT is the exact
  # canonical stdout envelope, CAPTURE_ERR is the diagnostic stream, and the
  # returned message is extracted and scanned as its own channel as well.
  for question in validate expected-plan; do
    probe "quiet-$question" "$question" \
      "$work/plan-inline-secret-value.json.authored" "$synthetic_digest"
    if [ "$CAPTURE_RC" -ne 0 ]; then
      note "$id" "the successor $question channels could not be observed"
      ok=0
    fi
    message="$work/quiet-$question.message"
    : > "$message"
    property get "$CAPTURE_OUT" message > "$message" 2>/dev/null || :
    for channel in "$CAPTURE_OUT" "$CAPTURE_ERR" "$message"; do
      if grep -Fq "$canary" "$channel" 2>/dev/null; then
        note "$id" "the successor $question channel echoed the synthetic secret value"
        ok=0
      fi
    done
  done
  # And the evidence a neighbouring valid plan carries.
  if structural_is valid accept && grep -Fq "$canary" "$work/plan-valid.json" 2>/dev/null; then
    note "$id" 'projected evidence carried the synthetic secret value'
    ok=0
  fi
  if [ "$ok" -eq 1 ]; then
    pass "$id" "$text"
  else
    fail "$id" "$text"
  fi
}

# ---------------------------------------------------------------------------
# WF-PLAN-SECRET-REFERENCE -- corroborates SEC-PLAN-INLINE-SECRET
# ---------------------------------------------------------------------------

scenario_secret_reference() {
  local id='WF-PLAN-SECRET-REFERENCE'
  local text='an adjacent bounded logical secret reference is accepted and projected as a reference'
  local ok=1
  if ! structural_is valid accept; then
    note "$id" "the bounded reference manifest was not projected (${fixture_verdict[valid]:-absent})"
    fail "$id" "$text"
    return
  fi
  if ! property plan-shape "$work/plan-valid.json" present >/dev/null 2>&1; then
    note "$id" 'the projected plan does not have the declared-reference shape'
    ok=0
  fi
  if ! matches_broker_reference "$work/plan-valid.json" >/dev/null 2>&1; then
    note "$id" 'the exact authored name/reference pair did not survive projection'
    ok=0
  fi
  if ! property no-material "$work/plan-valid.json" >/dev/null 2>&1; then
    note "$id" 'the projected plan carries secret material or a host path'
    ok=0
  fi
  if [ "$ok" -eq 1 ]; then
    pass "$id" "$text"
  else
    fail "$id" "$text"
  fi
}

# ---------------------------------------------------------------------------
# SEC-PLAN-SECRET-GRANT -- property
# ---------------------------------------------------------------------------

scenario_secret_grant() {
  local id='SEC-PLAN-SECRET-GRANT'
  local text='every template grant is a duplicate-free subset of the declared logical secret references'
  local ok=1 fixture_name reason operation mutant
  if [ ! -d "$successor_contract" ]; then
    note "$id" 'the successor contract root is absent'
    fail "$id" "$text"
    return
  fi
  for fixture_name in grant-undeclared grant-duplicate grant-host-path grant-selectable; do
    if ! structural_is "$fixture_name" reject; then
      note "$id" "$fixture_name was not refused (${fixture_verdict[$fixture_name]:-absent})"
      ok=0
    fi
  done

  # The product's own successor seam is asked the same question about the same
  # invalid grant sets, and must refuse each one without publishing a plan.  A
  # structural verdict alone would be satisfied by an implementation that
  # silently intersects an out-of-set grant or drops a duplicate one.
  if [ "$seam_present" -eq 1 ]; then
    for fixture_name in grant-undeclared grant-duplicate grant-host-path; do
      reason="$(product_refuses "$fixture_name" \
        "$work/plan-$fixture_name.json.authored" validate expected-plan)"
      if [ "$reason" != 'refused' ]; then
        note "$id" "the product seam did not refuse $fixture_name ($reason)"
        ok=0
      fi
    done
    # grant-selectable never becomes an authored document at all: a grant set
    # that is still an unresolved alternative is refused before any manifest
    # exists, so there is nothing to hand the product.  The product is asked
    # about that shape, and about an out-of-set grant, through mutants derived
    # here rather than stored, so fixture recognition cannot answer either.
    for operation in object-grant undeclared-grant; do
      mutant="$work/grant-mutant-$operation.json"
      if ! property mutate "$work/plan-valid.json.authored" "$operation" "$mutant" \
           >/dev/null 2>&1; then
        note "$id" "the $operation mutant could not be derived"
        ok=0
        continue
      fi
      if [ "$(schema_project "$mutant" "$work/grant-mutant-plan-$operation.json")" != 'reject' ]; then
        note "$id" "a derived $operation input was not refused by the contract"
        ok=0
      fi
      reason="$(product_refuses "derived-$operation" "$mutant" validate expected-plan)"
      if [ "$reason" != 'refused' ]; then
        note "$id" "the product seam did not refuse a derived $operation input ($reason)"
        ok=0
      fi
    done
  else
    note "$id" "the successor seam is absent: $seam_missing"
    ok=0
  fi

  if structural_is valid accept; then
    # The rule, checked against what was actually projected rather than against
    # a second implementation of the projection.
    if ! property plan-shape "$work/plan-valid.json" present >/dev/null 2>&1; then
      note "$id" 'the projected grant sets are not a canonical duplicate-free subset'
      ok=0
    fi
    # Cross-oracle: the product's own derivation and the pinned CUE projection
    # answer identically, so neither can drift alone.
    if [ "$seam_present" -eq 1 ]; then
      probe expected-valid expected-plan "$work/plan-valid.json.authored" "$synthetic_digest"
      if [ "$CAPTURE_RC" -ne 0 ] \
         || [ "$(property get "$CAPTURE_OUT" verdict 2>/dev/null)" != 'accept' ]; then
        note "$id" 'the product successor derivation did not produce a plan'
        ok=0
      else
        property extract "$CAPTURE_OUT" plan "$work/expected-valid.json" >/dev/null 2>&1 \
          || ok=0
        if ! property same "$work/expected-valid.json" "$work/plan-valid.json" >/dev/null 2>&1; then
          note "$id" 'the product derivation and the pinned CUE projection disagree'
          ok=0
        fi
      fi
    else
      note "$id" "the successor derivation is absent: $seam_missing"
      ok=0
    fi
  else
    note "$id" "the declared-grant manifest was not projected (${fixture_verdict[valid]:-absent})"
    ok=0
  fi
  if [ "$ok" -eq 1 ]; then
    pass "$id" "$text"
  else
    fail "$id" "$text"
  fi
}

# ---------------------------------------------------------------------------
# WF-PLAN-GRANT-NEIGHBOR -- corroborates SEC-PLAN-SECRET-GRANT
# ---------------------------------------------------------------------------

scenario_grant_neighbor() {
  local id='WF-PLAN-GRANT-NEIGHBOR'
  local text='a fixed declared grant neighbor projects deterministically and is reorder-invariant'
  local ok=1 repeat
  if ! structural_is valid accept || ! structural_is valid-reordered accept; then
    note "$id" 'the declared neighbour pair was not projected'
    fail "$id" "$text"
    return
  fi
  # Deterministic: the same authored bytes project to the same plan twice.
  repeat="$work/plan-valid-repeat.json"
  if [ "$(structural_verdict "$fixtures/valid.cue" "$repeat")" != 'accept' ] \
     || ! property same "$work/plan-valid.json" "$repeat" >/dev/null 2>&1; then
    note "$id" 'the projection is not deterministic'
    ok=0
  fi
  # Reorder-invariant: genuinely different authored bytes, identical plan.
  if cmp -s "$fixtures/valid.cue" "$fixtures/valid-reordered.cue"; then
    note "$id" 'the reordered neighbour is not a distinct authored source'
    ok=0
  fi
  if ! property same "$work/plan-valid.json" "$work/plan-valid-reordered.json" >/dev/null 2>&1; then
    note "$id" 'a reordered authored source did not project onto the same plan'
    ok=0
  fi
  if [ "$ok" -eq 1 ]; then
    pass "$id" "$text"
  else
    fail "$id" "$text"
  fi
}

# ---------------------------------------------------------------------------
# SEC-PLAN-GRANT-UNKNOWN -- corroborates SEC-PLAN-SECRET-GRANT
#
# The anti-fingerprinting control.  Every input here is derived from the valid
# manifest at run time, so an implementation that recognises the stored fixtures
# cannot answer these.
# ---------------------------------------------------------------------------

scenario_grant_unknown() {
  local id='SEC-PLAN-GRANT-UNKNOWN'
  local text='malformed, unknown, and reordered inputs are decided by rule rather than by fixture identity'
  local ok=1 operation mutant projected reason
  if ! structural_is valid accept; then
    note "$id" 'no accepted base manifest is available to derive mutants from'
    fail "$id" "$text"
    return
  fi
  for operation in unknown-member-field unknown-spec-field undeclared-grant \
                   duplicate-grant host-path-grant object-grant; do
    mutant="$work/derived-$operation.json"
    projected="$work/derived-plan-$operation.json"
    if ! property mutate "$work/plan-valid.json.authored" "$operation" "$mutant" >/dev/null 2>&1; then
      note "$id" "the $operation mutant could not be derived"
      ok=0
      continue
    fi
    if [ "$(schema_project "$mutant" "$projected")" != 'reject' ]; then
      note "$id" "a derived $operation input was not refused"
      ok=0
    fi
    reason="$(product_refuses "derived-$operation" \
      "$mutant" validate expected-plan)"
    if [ "$reason" != 'refused' ]; then
      note "$id" "both product seams did not refuse a derived $operation input ($reason)"
      ok=0
    fi
  done
  # A derived benign change is still accepted, and changes the plan: the rule
  # discriminates rather than refusing everything unfamiliar.
  mutant="$work/derived-rename-member.json"
  projected="$work/derived-plan-rename-member.json"
  if ! property mutate "$work/plan-valid.json.authored" rename-member "$mutant" >/dev/null 2>&1; then
    note "$id" 'the benign mutant could not be derived'
    ok=0
  elif [ "$(schema_project "$mutant" "$projected")" != 'accept' ]; then
    note "$id" 'a derived benign input was refused'
    ok=0
  elif ! property differ "$projected" "$work/plan-valid.json" >/dev/null 2>&1; then
    note "$id" 'a derived benign change did not change the projected plan'
    ok=0
  elif ! property plan-shape "$projected" present >/dev/null 2>&1; then
    note "$id" 'a derived benign projection lost the declared-grant properties'
    ok=0
  fi
  if [ "$ok" -eq 1 ]; then
    pass "$id" "$text"
  else
    fail "$id" "$text"
  fi
}

# ---------------------------------------------------------------------------
# Emission, in the frozen order.
# ---------------------------------------------------------------------------

scenario_legacy_inspectable
scenario_plan_executable
scenario_authority_denial
scenario_inline_secret
scenario_secret_quiet
scenario_secret_reference
scenario_secret_grant
scenario_grant_neighbor
scenario_grant_unknown

printf '%s\n' "${expected_ids[@]}" > "$work/expected-ids"
if ! cmp -s "$work/expected-ids" "$observed"; then
  printf 'INFRA g1 plan-authority assertion identity drift\n' >&2
  infrastructure=1
fi

finish
