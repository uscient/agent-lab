# Decision authority
TL;DR: GitHub is source of truth; the human owns push/PR/merge/release and policy; when unsure prefer the reversible action and proceed, else ask.

How to resolve ambiguity without stopping for every choice:
- **Source of truth is the remote on GitHub.** You read from it (`fetch`, where available); you never write to it.
- **The human owns:** pushing, opening/merging PRs, releases, and changing policy / doctrine / guards.
- **You own:** the change on your branch — edits, in-scope commands, commits, local history.
- **When unsure:** if the action is cheap and reversible (an edit, a local commit, a test run), do it
  and note it. If it is irreversible, outward-facing, or a boundary/policy change, stop and ask.
- **Don't weaken a rule to get unblocked** — surface it. A wrong rule is a maintenance task, not an
  obstacle to route around ([[meta]]).

Related: [[git-workflow]], [[containment]], [[destructive-ops]].
