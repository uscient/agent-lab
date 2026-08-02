# Agent-managed workstreams

A workstream lets an agent integrate one or more independently tested slices without receiving
authority over `dev`. The same workflow applies to a one-slice task and a longer delivery program.

```text
dev
`-- work/<slug>
    |-- slice/<slug>/<first>
    `-- slice/<slug>/<next>
```

Start a workstream from a clean checkout. The command fetches `origin/dev`, creates the remote
workstream ref at that exact commit, and switches to its tracking branch:

```bash
./scripts/dev/workstream start <slug>
```

Create each slice from the current remote workstream tip:

```bash
./scripts/dev/workstream slice <slice>
# develop, test, commit, and push slice/<slug>/<slice>
./scripts/dev/workstream pr --title "..." --body-file /tmp/pr-body.md
```

Read the PR, checks, Actions logs, and review state. After every check has completed successfully,
integrate the slice with:

```bash
./scripts/dev/workstream merge <pr-number>
```

The merge command rereads immutable PR metadata immediately before the operation. It requires an
open, non-draft, cleanly mergeable `slice/<slug>/<slice>` PR into the matching `work/<slug>`, rejects
requested changes, requires a successful `Required gates` check, requires every reported check to
be completed and successful, and pins the merge to the observed head commit. It always preserves
slice commits with a merge commit. Direct PR merge commands remain blocked.

When all planned slices are integrated, switch to the workstream branch, inspect the complete range,
run final gates, and open the human-owned integration PR:

```bash
./scripts/dev/workstream final --title "..." --body-file /tmp/pr-body.md
```

The final PR always targets `dev` and is always created as a draft. Agents cannot merge it.

## Project guides

Files under ignored `proj/` may define slice order, contracts, dependencies, RED/GREEN/mutation
evidence, and stop conditions. A guide coordinates work but grants no authority and cannot weaken
`AGENTS.md`, the workstream command, required checks, or containment. Record the workstream slug,
base commit, ordered slice names, per-slice branch/PR, evidence ledger, and remaining uncertainty.
