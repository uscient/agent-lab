# Contributing to agent-lab

**This project does not accept contributions from non-members.**

Pull requests and issues from anyone who is not a member of the organization will be closed without review.

## Why?

`agent-lab` is a specialized, opinionated containment lab. It is developed under a strict internal process (see `AGENTS.md` and the guard tooling) to maintain its security and design invariants. We do not have the bandwidth or model to review external contributions.

## What you _can_ do

- Use the code locally for your own experiments (Apache 2.0 license).
- Fork the repository for personal or internal use.
- File issues **only** if you are a member (they will still be triaged internally).
- Organization members report security issues through the established private channel. This mirror
  publishes no external intake; see [SECURITY.md](../SECURITY.md).

## For organization members

- Follow the [branch, metadata, and integration workflow](../docs/development.md#branch-and-integration-workflow).
- Publish only the current branch and use its exact derived PR base: ordinary/workstream work targets
  `dev`, program groups target `flow`, and slices target their matching parent.
- Treat `dev`, `flow`, `master`, and `main` as protected. Agents may merge only an approved, current,
  green intermediate PR through `scripts/dev/workstream`; humans merge every final PR into `dev`.
- Preserve merge ancestry and branch/PR evidence. The required hosted protections and exact program
  routes are in [Workstreams and programs](../docs/workstreams.md).

If you have questions about using the lab locally, start with the
[README](../README.md) and [documentation map](../docs/README.md). There is no
separate public support channel.

Thank you for understanding.
