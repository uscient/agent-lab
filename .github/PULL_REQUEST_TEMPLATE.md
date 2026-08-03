## Summary

<!-- State the delivered outcome in one or two sentences. -->

## Motivation / Context

<!-- Explain the problem, boundary, or decision this change addresses. -->

## Changes

<!-- List the reviewable changes and call out meaningful exclusions. -->

## Testing

<!-- List commands in backticks with observed pass, fail, blocked, or skipped results.
If nothing ran, write: Not run — reason. -->

## Evidence

<!--
The PR body is the durable evidence ledger. Append a new Cycle after every invalidating change;
never erase or rewrite an earlier cycle. Replace every value below. Use `N/A — reason` only when a
field genuinely does not apply. PR prose is not proof of GREEN: current-head Required gates and
CodeQL remain authoritative.

### Cycle 1

- Route: `HEAD_BRANCH` -> `BASE_BRANCH`
- Base: `EXACT_40_HEX_BASE_SHA`
- Head: `EXACT_40_HEX_HEAD_SHA`
- Scenarios: `WF-ID`, `SEC-ID`, or N/A — reason
- Assertions: `ASSERTION-ID`
- RED predecessor: `EXACT_40_HEX_PREDECESSOR_SHA`
- RED: `exact command` — rc=1 classification=assertion-failure
- GREEN: `exact command` — rc=0 classification=success
- Product mutation: `mutation ID` — detected rc=1 classification=assertion-failure
- CI mutation: `mutation ID` — detected rc=1 classification=assertion-failure
- Runner: runner and Engine facts
- Duration: measured duration
- Cleanup: cleanup result
- Artifacts: identifiers and checksums, or N/A — reason
- Unverified: remaining claims, or none
-->

## Checklist

- [ ] Change is minimal and focused
- [ ] Fast gate passes with the appropriate diff base (see `docs/ci.md`)
- [ ] Relevant strict/static or Docker gate has been run, or its omission is explained
- [ ] No secrets or policy violations introduced
- [ ] Follows the internal process in `AGENTS.md`
