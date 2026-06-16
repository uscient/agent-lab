# Destructive / integrity operations
TL;DR: Irreversible/destructive ops (rm -rf, git reset --hard, git clean -fdx, history rewrite, broad chmod/chown, sudo, sed -i) are denied under autonomy — ask the human.

Autonomy is broad for routine work, but a defined set is held back because a mistake is
unrecoverable or destroys work that isn't yours to discard:
- mass deletion: `rm -rf`, broad recursive removal;
- history / state loss: `git reset --hard`, `git clean -fdx`, interactive rebase,
  `filter-branch`/`filter-repo`, `git branch -D`, mass `checkout -- .` / `restore .`;
- broad permission changes: recursive or world-writable `chmod`/`chown`;
- privilege / in-place edits: `sudo`, `sed -i`.

These are denied by the guard (exit 2), not merely discouraged. If you genuinely need one, say what
and why and let the human run or sanction it. Don't route around the guard — that itself is a
violation ([[meta]]).

Related: [[git-workflow]], [[decision-authority]].
