# CI as an agent-facing gate

Agent Lab CI is a versioned contract, not an advisory test counter. It runs on
merge-queue candidates, pushes to `dev`, `flow`, `master`, and `main`, and pull
requests targeting those branches plus `work/**` and `group/**`. It exposes one stable result:
**`CI / Required gates`**.

`dev` remains authoritative. `flow` is the protected program base, `group/**`
receives only its matching `slice/group/**`, and `work/**` receives only its
matching legacy slice. Fast CI rejects cross-repository or level-skipping PR
topologies. The `master` and `main` triggers protect retained publication or
compatibility names; a trigger grants no integration authority. See
[Development and verification](development.md) for the exact routes.

## Required workers

| Check | Claim | Exact local replay |
| --- | --- | --- |
| `CI / Fast` | pinned CUE and Cedar provisioning, changed-file guard, shell/unit contracts, and Docker-free security gate | `AGENT_LAB_DIFF_BASE=THE_SHA_FROM_GATE_SUMMARY ./scripts/dev/ci-fast` |
| `CI / Static` | strict Compose rendering and static configuration invariants | `./tools/validate.sh --strict` |
| `CI / Docker security` | deterministic runtime containment evidence | `./scripts/dev/docker-gate` |

The `Required gates` job consumes GitHub's structured `needs` result, compares
it with `tests/security/ci.manifest`, and succeeds only when the exact required
set is present, every result is `success`, every worker classifies that result
as success, and every worker binds evidence to the exact event head. It combines
the Fast worker's validated event base with the versioned replay command, so its
summary contains a concrete command rather than a guessed Git ref. Assertion
failures block with `1`; missing, extra, stale, skipped, cancelled, malformed,
or infrastructure-uncertain evidence fails closed with `125`.

CodeQL remains a separate check because GitHub does not expose cross-workflow
jobs through `needs`. Its workflow and job names are fixed as `CodeQL` so the merge helper and
hosted rules can require the same unambiguous Actions result. GitHub also emits a same-named
code-scanning result; that result must succeed but cannot substitute for the workflow job.

The Docker worker always runs the full runtime gate. Its cache-aware devbox
build is a separate timed step, and the gate records runtime-suite timings so
slow phases remain visible without turning containment evidence into an
optional check. The optional OpenClaw image is not built by CI.

## Agent navigation loop

1. Open `CI / Required gates` for the compact result table and replay commands.
2. Open the failed worker for its focused step summary and annotation.
3. Download its seven-day failure artifact, when produced, if the normal log is
   too noisy.
4. Reproduce with the exact command from the table.
5. Fix the source defect; do not weaken assertions, convert failures to skips,
   or add blanket retries.

The fast job records and validates the immutable event diff base and checked-out
head. It rejects missing, malformed, unfetched, non-ancestor, or mismatched SHAs
rather than guessing `HEAD^`. The sole zero-predecessor exception is the human creation of literal
`flow` at the exact bootstrap-closure `dev` commit before another `dev` merge. CI requires that
head to equal current `origin/dev` and proves it contains the immutable recorded R0 merge; that push
still runs the complete gates and CodeQL.

For pull requests, the fast job also reads the body only from the GitHub event file and validates the
latest append-only evidence cycle against the event's exact base/head SHAs and route. Body edits must
preserve every prior cycle. Program routes and base-policy protected changes require non-`N/A` RED
predecessor, RED, GREEN, product mutation, and CI mutation. Missing, malformed, stale,
skipped-as-green, or mutation-insensitive required evidence is not GREEN. PR-body prose complements
current-head statuses and review; it does not replace either one.

## Trust boundary

The required status is navigation and merge evidence, not a standalone security
boundary. Pull-request code can change workflows, reducers, manifests, and the
tests they execute while preserving the same check name. The human-owned review
gate remains authoritative.

Before granting autonomous agents any merge authority, require an approval of
the most recent push and dismiss stale approvals. Also require code-owner review
by a real maintainer team for `.github/workflows/`, `scripts/dev/`,
`scripts/lib/dev-common.sh`, and `tests/security/`; alternatively, enforce a
required workflow or path restriction whose definition agents cannot modify.
Do not add a placeholder CODEOWNER: GitHub silently ignores owners that lack
write access.

## Repository ruleset

After each base has emitted its first check, require `CI / Required gates` and
CodeQL on `dev`, `flow`, every `group/**` base, and any retained publication
branch. Require current-base testing, approval of the latest push, and stale-approval dismissal;
the verified program route does not use a merge queue. Deny force updates and deletion for
`flow`, `work/**`, `group/**`, and `slice/group/**`; keep merge commits and disable
automatic program-branch deletion through final review.

Do not require worker or matrix names individually. The stable aggregate is the
public contract; its versioned manifest defines the internal required set.

Related references:

- [Documentation map](README.md)
- [Security verification](../SECURITY.md#security-verification)
- [Threat model](../THREAT_MODEL.md)
