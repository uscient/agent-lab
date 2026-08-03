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
| `group/<group>` | merge `origin/flow` via `sync` | `flow` | verified helper after approval |
| `slice/group/<group>/<slice>` | merge `origin/group/<group>` via `sync` | `group/<group>` | verified helper |
| protected `flow` | no agent sync or write | `dev` | human |

`<work>` and `<slice>` are 1–48 lowercase alphanumeric/hyphen characters and start alphanumeric.
`<group>` is also at most 48 characters and matches
`[gb][0-9]+[a-z]?-[a-z0-9][a-z0-9-]*`. The word `group` in the group-slice form is literal. Legacy
slices cannot target a group or `flow`, and program branches cannot target a legacy workstream.

## R0 bootstrap

`flow` does not exist until the R0 rail-maintenance PR has been reviewed and merged into `dev`. A
human must record that exact R0-updated `dev` commit, create `flow` at that exact SHA, and install the
hosted protections below before any group is created. A prior `dev` commit, a later moving ref, or an
agent-created substitute is not an accepted bootstrap. This creation is the sole supported
zero-predecessor `flow` push and still runs CI and CodeQL.

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

After the human R0 bootstrap, create a group at the fetched `origin/flow` commit:

```bash
./scripts/dev/workstream group g0-operator-surface
```

A group may be developed directly or split into reviewable slices. From the group branch:

```bash
./scripts/dev/workstream slice cli
# develop, test, commit, sync, and push slice/group/g0-operator-surface/cli
./scripts/dev/workstream pr --title "..." --body-file /tmp/pr-body.md
```

Each group slice must be approved, current, and green before the helper merges it from the matching
group checkout. When the group is complete, sync it with `flow`, replay the complete evidence, push
it, and open its fixed draft PR:

```bash
./scripts/dev/workstream group-pr --title "..." --body-file /tmp/pr-body.md
```

The group PR always targets `flow` and starts as a draft. A human makes it ready and supplies the
required approval. Once its current head contains the observed current `flow` base and every required
check succeeds, an agent may check out read-only `flow` and run:

```bash
./scripts/dev/workstream merge <pr-number>
```

The resulting `flow` head must complete CI and CodeQL before another group integrates. After all
groups are integrated, a human or an agent may open the final draft while checked out on `flow`:

```bash
./scripts/dev/workstream final --title "..." --body-file /tmp/pr-body.md
```

Only a human merges that final non-squash `flow` → `dev` PR.

## Synchronization and verified merge

Run `./scripts/dev/workstream sync` only from a clean `work/*`, `group/*`, or matching slice branch.
For `work/*` and `group/*`, it fetches both the branch's own remote integration ref and its derived
`dev`/`flow` parent, then fast-forwards the local branch to its remote ref. It refuses local/remote
divergence instead of rewriting accepted history. Slice creation performs the same refresh before it
branches. Reusable `work/*`, program `group/*`, and `slice/group/*/*` always merge their moving
parent; none may be rebased or force-updated after publication. A legacy slice may rebase only on
its matching workstream. Replay invalidated evidence after any sync.

`workstream merge` rereads hosted PR state immediately before acting. It accepts only a same-repository
PR whose base is the current checkout and whose head is the exact matching slice or group route. The
PR must be open, non-draft, cleanly mergeable, approved, contain its observed current base, report
exactly one successful `Required gates` and `CodeQL` check, and have every reported check completed
successfully. Group integration also requires those checks green on the observed `flow` base.
Every GitHub read and write is pinned to `github.com/uscient/agent-lab`; ambient repository or host
environment variables cannot redirect the helper.
The command requests a merge commit pinned to the observed head SHA and confirms GitHub reports the
PR as merged. It never squashes, rebases, force-updates, or deletes a branch. Direct `gh pr merge`
remains blocked. If GitHub queues the PR, an open PR is not reported as completed; treat it as pending
until the queue records `MERGED` on the same checked head.

## Human GitHub configuration

Repository files test the client-side route, but humans must install and audit the hosted rules:

- Protect `dev`, `flow`, `master`, `main`, `work/**`, `group/**`, and `slice/group/**`; prohibit unauthorized
  direct pushes, every program-branch force update, and deletion.
- Require pull requests, `CI / Required gates`, and `CodeQL` on every protected branch that receives
  changes. Require the PR head to contain the current base or use the merge queue; the helper pins
  the head, but only this hosted rule closes a base movement between validation and merge.
- Require approval, dismiss stale approval after new commits, and require approval of the latest
  reviewable push. Rules for intermediate bases must preserve the helper's same guarantees.
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
Record exact base and head commits, the PR route, commands and results, approvals, mutations,
artifacts, cleanup, superseding runs, and remaining uncertainty. Append new evidence; do not erase
the record a later run supersedes.
