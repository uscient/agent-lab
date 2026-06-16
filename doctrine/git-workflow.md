# Git workflow
TL;DR: Work on agent/<tool>/<slug>; commit freely; never push, pull, or integrate remote state (no merge/rebase from origin/*), and never open a PR — the human owns the remote and the merge gate.

- On master/main/detached, a branch `agent/<tool>/<slug>` is created for you (SessionStart). If it
  wasn't, create one before committing.
- **Allowed:** add, commit (incl. `--amend`), branch/switch/checkout, stash, restore (worktree),
  local merge/rebase between your own branches, and `fetch` (where the profile supports it).
- **Denied (guard, exit 2):** push (any form); pull; `merge`/`rebase` from a remote-tracking ref
  (`origin/*`, `refs/remotes/*`) — that is the 2nd half of a pull, so denying `pull` alone is not
  enough; `gh pr` / remote-writing `gh`; `git remote` mutation. Enforced — don't route around them.
- **Profile note:** under Codex v1 the sandbox network is off, so `fetch` isn't available in-session;
  the human / CI / wrapper refreshes remote state before the session starts.
- **Done** = a clean local commit on the branch + a short handoff. The human reviews and opens the PR.

Related: [[decision-authority]], [[meta]].
