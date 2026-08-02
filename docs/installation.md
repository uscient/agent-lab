# Local installation

## Program bundle

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

## Initialized home

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

## Installed Experiment evidence

After initialization and tool provisioning, install or inspect an Experiment with the same local
program bundle:

```bash
agent-lab --home /absolute/private/home experiment install ./my-experiment
agent-lab --home /absolute/private/home experiment install --zip ./my-experiment.zip
agent-lab --home /absolute/private/home experiment install --git https://github.com/owner/repository.git --commit <40 lowercase hex>
agent-lab --home /absolute/private/home experiment inspect NAME
```

The configured experiments component is private `0700` state. Each successful first install
publishes this closed layout without overwriting an existing name:

```text
<experiments>/
|-- .staging/                         0700
`-- NAME/                             0500
    |-- artifact/                     0500
    |   `-- experiment.cue            0400
    `-- records/                      0500
        |-- decision.json             0400
        |-- install.json              0400
        |-- plan.json                 0400
        `-- provenance.json           0400
```

`install.json` binds the requested name, source, domain-separated plan identity, contract,
authorization, exact selected image entries, and the schema and digest of every other stored file.
`installationKey` is the domain-separated digest of that installation identity; `receiptDigest`
identifies the closed receipt itself. Provenance records the source transport and exact catalog
evidence: `catalog` is `null` for direct digests, `catalog.bundled.snapshotDigest` identifies a
release-owned bundled snapshot, and `catalog.local` contains the checked local snapshot's `revision`
and `snapshotDigest`. Both nested entries are present when a plan uses both namespaces. Provenance
also records one closed source transport: local directory, bounded ZIP byte count and digest, or
canonical public GitHub URL, exact commit/tree/blob identities, and bounded acquisition facts.
Transport provenance is evidence, not authority for a later operation and is excluded from the
installation identity, so equivalent directory, ZIP, and Git sources retry idempotently.

Every read reopens and verifies the closed layout, canonical bytes, digests, schemas, ownership,
modes, and link counts. `experiment inspect` does this under the shared store lock and never writes
or repairs. An effectful retry takes the lock exclusively and may reconcile only a recognized,
bounded staging operation against the final receipt. Unknown, unsafe, or conflicting state returns
`125` without broad deletion. These controls are tamper-evident for a cooperative local account;
they are not same-user immutability.
