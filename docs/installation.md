# Local installation

Install the current verified Agent Lab program bundle for one user:

```bash
./scripts/install-local
# or
./scripts/install-local --prefix /absolute/private/prefix
```

The default prefix is the account-database home plus `.local`; ambient `HOME` is not authority.
`--prefix` takes precedence over `AGENT_LAB_PREFIX`. Installation copies only the closed runtime
manifest into a content-addressed release and atomically publishes `<prefix>/bin/agent-lab`. It does
not use sudo, edit shell profiles, initialize data, or download tools. Add the prefix's `bin`
directory to `PATH` yourself if desired.

Initialize a separate private Agent Lab home:

```bash
agent-lab --home /absolute/private/home init
agent-lab --home /absolute/private/home config check
agent-lab --home /absolute/private/home config show
agent-lab --home /absolute/private/home tools provision
```

The default mutable home is the account-database home plus `.agent-lab`; `--home` takes precedence
over `AGENT_LAB_HOME`. Ambient `HOME` is ignored. The first `init` may choose distinct safe
single-component names with `--experiments-dir`, `--images-dir`, `--cache-dir`, and `--state-dir`.
Those choices are frozen by `home.json`; later drift or conflicting initialization is refused.
The same receipt binds the device, inode, relative path, and schema of both stable lock files.
`config check` and exact `init` retry refuse a replaced lock or unexpected lock contents as
infrastructure uncertainty.

`tools provision` is the only foundation command allowed to acquire the pinned CUE and Cedar
binaries. Normal commands never download them automatically. Program releases, Experiment data,
image-catalog state, tool cache, and locks remain in separate guarded trees. Exact reinstall and
exact init retry are idempotent; this version does not implement release garbage collection or
in-place home-layout migration.
