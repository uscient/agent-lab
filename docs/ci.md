# CI as an agent-facing gate

Agent Lab CI is a versioned contract, not an advisory test counter. It runs on
pull requests, merge-queue candidates, and pushes to `dev`, `master`, and
`main`, and exposes one stable branch-protection result:
**`CI / Required gates`**.

## Required workers

| Check | Claim | Exact local replay |
| --- | --- | --- |
| `CI / Fast` | changed-file guard, shell/unit contracts, and Docker-free security gate | `AGENT_LAB_DIFF_BASE=<SHA from the gate summary> ./scripts/dev/check default quick` |
| `CI / Static` | strict Compose rendering and static configuration invariants | `./tools/validate.sh --strict` |
| `CI / Docker security` | deterministic runtime containment evidence | `./scripts/dev/docker-gate` |

The `Required gates` job consumes GitHub's structured `needs` result, compares
it with `tests/security/ci.manifest`, and succeeds only when the exact required
set is present and every result is `success`. It combines the Fast worker's
validated event base with the versioned replay command, so its summary contains
a concrete command rather than a guessed Git ref. A missing, extra, skipped,
cancelled, malformed, or unknown result fails closed.

CodeQL remains a separate check because GitHub does not expose cross-workflow
jobs through `needs`.

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

The fast job records and validates the immutable event diff base. It rejects
missing, zero, malformed, unfetched, or non-ancestor SHAs rather than guessing
`HEAD^`.

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

After the workflow has emitted its first check, require `CI / Required gates`
on both `dev` and `master`. Require CodeQL through the repository's code-scanning
rule. Enable the up-to-date-branch requirement or a merge queue so the tested
synthetic merge commit includes the current integration branch.

Do not require worker or matrix names individually. The stable aggregate is the
public contract; its versioned manifest defines the internal required set.
