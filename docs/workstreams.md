# Agent-managed workstreams and programs

The workstream helper supports two bounded integration shapes without granting general merge
authority. Legacy workstreams collect unrelated repository slices under `work/*`. Delivery programs
collect major groups under the protected `flow` branch. `dev` remains authoritative.

```text
dev
|-- ordinary work branch ------------------------------> dev (human merge)
|-- work/<work>
|   `-- slice/<work>/<slice> -----------> work/<work> --> dev (human final merge)
`-- flow [protected]
    `-- group/<group>
        `-- slice/group/<group>/<slice> -> group/<group> -> flow
                                                        `-> dev (human final merge)
```

## Exact routes

| Head branch | Sync/rebase base | Pull-request base | Merge owner |
|---|---|---|---|
| ordinary branch | `origin/dev` | `dev` | human |
| `work/<work>` | merge `origin/dev` via `sync` | `dev` | human |
| `slice/<work>/<slice>` | `origin/work/<work>` | `work/<work>` | verified helper |
| `group/<group>` | PR-only `group-sync` slice from `origin/flow` | `flow` | verified helper |
| `slice/group/<group>/<slice>` | merge `origin/group/<group>` via `sync` | `group/<group>` | verified helper |
| protected `flow` | no agent sync or write | `dev` | human |

`<work>` and `<slice>` are 1–48 lowercase alphanumeric/hyphen characters and start alphanumeric.
`<group>` is also at most 48 characters and matches
`[gb][0-9]+[a-z]?-[a-z0-9][a-z0-9-]*`. The word `group` in the group-slice form is literal. Legacy
slices cannot target a group or `flow`, and program branches cannot target a legacy workstream.

## Flow bootstrap closure

`flow` does not exist until the R0 rail-maintenance PR and any required pre-bootstrap closure work
have been reviewed and merged into `dev`. A human freezes further `dev` integration, records the
then-current bootstrap-closure `dev` commit, and creates `flow` at that exact SHA before another
`dev` merge. The closure commit must contain the immutable R0 merge
`9ef827c1b0c947babd90ed251deefcd50c04947c`. CI proves both that ancestry and exact equality with
current `origin/dev`; an earlier ancestor, a later moving ref, an unrelated commit, or an
agent-created substitute is not accepted. This creation is the sole supported zero-predecessor
`flow` push and still runs complete CI and CodeQL. The human installs the hosted protections below
before any group is created. Keep `dev` frozen through those exact-head results and the protection
audit. For this bounded program, keep it frozen until the final human `flow` → `dev` merge; merge
queues are not part of the verified evidence route.

## Legacy workstream

From a clean checkout, create the remote workstream at the fetched `origin/dev` commit and switch to
its tracking branch:

```bash
./scripts/dev/workstream start <work>
```

Create a slice from the current remote workstream tip, develop and verify it, then publish its exact
route:

```bash
./scripts/dev/workstream slice <slice>
# develop, test, commit, sync, and push slice/<work>/<slice>
./scripts/dev/workstream pr --title "..." --body-file /tmp/pr-body.md
```

After approval and current-head checks, switch to the matching `work/<work>` branch and integrate the
slice:

```bash
./scripts/dev/workstream merge <pr-number>
```

When the workstream is complete, sync it, replay final gates, push it, and open the human-owned draft
PR:

```bash
./scripts/dev/workstream final --title "..." --body-file /tmp/pr-body.md
```

That final PR always targets `dev`; an agent cannot merge it.

## Program group

After the human bootstrap closure, create a group at the fetched `origin/flow` commit:

```bash
./scripts/dev/workstream group g0-operator-surface
```

Every Group after G0 is an integration parent, not a direct implementation branch. Before product
work begins, divide it into at least two independently GREEN vertical slices with explicit scenario
ownership and minimal overlap. A process-only synchronization or gate-registration slice does not
count toward that minimum. Give each active slice its own clean checkout and complete local workflow
packet; ignored packet state is never shared between checkouts. From the group branch:

```bash
./scripts/dev/workstream slice cli
# develop, test, commit, sync, and push slice/group/g0-operator-surface/cli
./scripts/dev/workstream pr --title "..." --body-file /tmp/pr-body.md
```

Each Group slice owns a falsifiable contract, intended RED, unchanged GREEN, relevant mutation
evidence, audit, exact-head CI, and concise handoff. Integrate accepted slices one at a time from the
matching Group checkout. Sync remaining slices with the moving Group parent and replay any evidence
invalidated by that merge. After all vertical slices integrate, run the complete Group custody,
coverage, GREEN, mutation, audit, and repository campaign.

Group branches cannot be pushed directly. When current `flow` is not already an ancestor, prepare
the deterministic retained-history synchronization slice, publish it, and send it through the same
Group-slice PR gates:

```bash
./scripts/dev/workstream group-sync
git push origin "$(git branch --show-current)"
./scripts/dev/workstream pr --title "chore: synchronize current flow" --body-file /tmp/pr-body.md
```

The generated branch is `slice/group/<group>/sync-flow-<12-hex-flow-sha>`. Once every slice and any
required synchronization PR is integrated, open the Group's fixed draft PR:

```bash
./scripts/dev/workstream group-pr --title "..." --body-file /tmp/pr-body.md
```

Group-slice and Group PRs start as drafts. For the bounded Flow program, the coordinator owns their
intermediate readiness and integration; from the exact current Group or matching Group-slice branch,
it makes the corresponding PR ready through the verified helper:

```bash
./scripts/dev/workstream ready <pr-number>
```

Group-slice and Group integration do not require an intermediate human approval, but
changes-requested state, draft state, stale base/head/evidence, missing checks, failed checks, or
non-merge ancestry still block them. Legacy workstream integration retains its approval requirement.
Once the Group head contains the observed current `flow` base and every required check succeeds, the
coordinator checks out read-only `flow` and runs:

```bash
./scripts/dev/workstream merge <pr-number>
```

After any pushed review fix, synchronization, or base movement, append the next complete evidence
cycle to a local body file and update only that branch-derived PR through the bounded helper:

```bash
./scripts/dev/workstream evidence <pr-number> /tmp/pr-body.md
```

The helper proves the repository, open PR number, current head/base names and SHAs, strict evidence
schema, and unchanged prior cycles before and after the edit. Direct `gh pr edit` remains blocked.

An opened PR body reaches GitHub before anything validates it, so a published first cycle can end a
canonical result token with comma-adjacent prose that strict validation rejects and append-only
refuses to correct. Only that case takes one bounded repair route through the same helper: the
replacement must pass the same strict current base, head, and route validation, the published body
must still fail that same validation, and the two ledgers must differ only by deleting a comma and
its nonempty trailing prose from one to four latest-cycle `RED`, `GREEN`, `Product mutation`, or
`CI mutation` lines whose prefix through the canonical result token is byte-identical. Earlier
cycles, other fields, result tokens, scenarios, assertions, SHAs, route, cycle count, and every
already-strict body stay on the byte-exact append-only path. The required workflow applies the same
bounded repair inside that edited run: it captures the append attempt, accepts the correction only
after it determines strict applicability, strictly validates the replacement against the event base,
head, and route, proves the published body still fails that identical validation with an assertion
result, and proves the difference through `evidence-repair`, then rules on the replacement with the
ordinary strict validation. The repair edit therefore completes its own exact-head hosted campaign;
it needs no later pushed head, no rerun, and no cancellation.

The resulting `flow` head must complete CI and CodeQL before another group integrates. After all
groups are integrated, a human or an agent may open the final draft while checked out on `flow`:

```bash
./scripts/dev/workstream final --title "..." --body-file /tmp/pr-body.md
```

Only a human merges that final non-squash `flow` → `dev` PR.

## Synchronization and verified merge

Run `./scripts/dev/workstream sync` only from a clean `work/*` or matching slice branch. A workstream
first fast-forwards to its own remote integration ref and then merges `origin/dev`; a Group slice
merges `origin/group/<group>`. The command refuses a Group branch because hosted rules require every
Group update to arrive by PR. `group-sync` first fast-forwards the local Group to its remote ref,
derives a collision-resistant branch from the exact `origin/flow` SHA, and creates one exact
two-parent merge without pushing it. Slice creation performs the same Group refresh before it
branches. Reusable workstreams, program Groups, and Group slices are never rebased or force-updated
after publication. A legacy slice may rebase only on its matching workstream. Replay invalidated
evidence after any sync.

`workstream merge` rereads hosted PR state immediately before acting. It accepts only a same-repository
PR whose base is the current checkout and whose head is the exact matching slice or group route. The
PR must be open, non-draft, cleanly mergeable, contain its observed current base, report
exactly one successful `CI` workflow job named `Required gates` and one successful `CodeQL` workflow
job named `CodeQL`, and have every reported check completed successfully. GitHub's separate
code-scanning result may also be named `CodeQL`; it neither substitutes for nor conflicts with the
workflow job. Legacy slice integration requires approval. Agent-owned Group-slice and Group
integration accepts no-review or approved state but always rejects changes-requested state. Group
integration also requires the GitHub Actions jobs green on the observed `flow` base.
Every GitHub read and write is pinned to `github.com/uscient/agent-lab`; ambient repository or host
environment variables cannot redirect the helper.
The command requests an immediate merge commit through GitHub's head-pinned merge endpoint and
confirms GitHub reports the PR as merged. It never enables auto-merge, enters a merge queue, squashes,
rebases, force-updates, or deletes a branch. A queue-required or non-immediate response is a refusal;
direct `gh pr merge` remains blocked.

## Human GitHub configuration

Repository files test the client-side route, but humans must install and audit the hosted rules:

- Protect `dev`, `flow`, `master`, `main`, `work/**`, `group/**`, and `slice/group/**`; prohibit unauthorized
  direct pushes, every program-branch force update, and deletion.
- Require pull requests, `CI / Required gates`, and `CodeQL` on every protected branch that receives
  changes. Require the PR head to contain the current base. The helper pins the head, but only this
  hosted rule closes a base movement between validation and merge. Do not require a merge queue on
  an intermediate program base.
- Require human approval, stale-approval dismissal, and approval of the latest reviewable push for
  final PRs into `dev`. Intermediate Group and Group-slice rules must permit the verified agent-owned
  route while preserving changes-requested blocking and every current-head check.
- Permit merge commits and disable squash/rebase merging. Disable automatic head-branch deletion;
  retain program branches and PR records through final `flow` review.
- Require trusted human ownership for every rail in `policy/protected.paths`, including workflows,
  gate manifests, reducers, the workflow checker/helper, guards, and their contract tests. The owner
  must be a real maintainer team with repository write authority.

Required checks must bind to the current head. A base change, dependency merge, workflow or manifest
change, rebase, or merge invalidates older green evidence and requires replay. Skipped, cancelled,
missing, stale, duplicate, or infrastructure-uncertain results are not green.

## Project guides and evidence

Files under ignored `proj/` may define group order, slice contracts, dependencies, behavior
scenarios, RED/GREEN/mutation evidence, and stop conditions. A guide coordinates work but grants no
authority and cannot weaken `AGENTS.md`, hosted rules, the helper, required checks, or containment.
The cadence is Behavior-Driven, Test-Driven, and Security-Driven: start from behavior scenarios, make
their behavior and security assertions RED, implement to GREEN, then run product and test/CI
sensitivity mutations before final gates.

For unattended Flow packets, keep Codex at `xhigh`, Claude Opus 5 at `max` when the client supports
it, and Grok 4.5 at `medium`. Stream a worker's own output when safe; otherwise poll that same
process. Never launch a status worker or alter a worker's configuration to observe it. Bash/Python
test workers do not start Serena unless semantic tooling is genuinely needed. Correction packets
contain only unresolved issue keys, controlling contract clauses, affected test functions, the
required patch, exact coverage validation, one intended RED, and concise per-issue disposition.
Repeat broader stubs, mutation matrices, aggregate harnesses, or registration proofs only when the
correction changes something they measure. The coordinator owns deterministic custody, lint,
coverage, and state-machine checks and avoids duplicating an authoritative state-machine run. None
of these latency rules weakens the full post-GREEN mutation campaign, exact-head CI, CodeQL,
custody, containment, or security gates.
Record exact base and head commits, the PR route, commands and results, approvals, mutations,
artifacts, cleanup, superseding runs, and remaining uncertainty. Append new evidence; do not erase
the record a later run supersedes.

The pull-request body is the smallest repository-independent durable ledger and uses the exact
`Evidence` cycle fields in the PR template. CI validates the body from the pull-request event against
that event's current base and head, and `scripts/dev/workstream merge` repeats the check immediately
before an intermediate merge. A new commit, rebase, or base movement requires an appended current
cycle; the CI edit event and bounded update helper reject changing or erasing an earlier cycle.
GitHub retains the PR and edit history, but this prose record is not cryptographically immutable.
Ignored `proj/` guides and `.cache/` artifacts are useful local inputs and supporting evidence, never
the only authoritative ledger. Program routes and rail changes use strict mode: RED predecessor,
RED, GREEN, product mutation, and CI mutation cannot be waived with `N/A`.

## Required-suite registration

Prefer extending an already registered required suite. Adding a new required suite or changing its
mode, tools, path, or exact final marker is explicit rail maintenance, not incidental product work.
The group scope names those fields before implementation. Use a dedicated
`slice/group/<group>/gate-registration` when practical, and atomically update the canonical manifest
and its independently authored exact inventory:

| Required set | Canonical manifest | Independent inventory |
|---|---|---|
| Fast | `tests/security/fast.manifest` | `tests/dev/security-gate-cases.sh` |
| Docker | `tests/security/docker.manifest` | `tests/dev/docker-harness-cases.sh` |
| CI workers | `tests/security/ci.manifest` | `tests/dev/required-gates-cases.sh` |

`AGENT_LAB_MAINTENANCE=1` only unlocks the local guard; it does not waive the intermediate helper or
final human authority. Complete current-head CI and CodeQL are replayed. Never derive the independent
inventory from its manifest or add an unprotected discovery registry: either change would let
product code silently choose its own required evidence.
