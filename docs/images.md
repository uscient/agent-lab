# Local image names

Agent Lab can assign one operator-local name to an already immutable OCI subject. The following
block is syntax notation; replace uppercase placeholders and either supply the optional home prefix
or omit it consistently:

```text
agent-lab --home ABSOLUTE_HOME image add VENDOR.IMAGE DIGEST_REF
agent-lab --home ABSOLUTE_HOME image inspect VENDOR.IMAGE
agent-lab --home ABSOLUTE_HOME image list
agent-lab --home ABSOLUTE_HOME image list --all
agent-lab --home ABSOLUTE_HOME image remove VENDOR.IMAGE --expect ENTRY_DIGEST
```

This catalog is shared by every Experiment using the same initialized Agent Lab home. It stores
names and digest-pinned references only. These commands do not call Docker, contact a registry,
download or inspect image bytes, perform admission, or assert that a subject is runnable.

## Names and subjects

A local name has exactly two lowercase ASCII components, `<vendor>.<image>`. Each component is 1–31
bytes, begins with a letter, and may contain digits or single hyphen-separated segments. The whole
name is at most 63 bytes. `agent-lab.*` is reserved for the release-owned bundled catalog and cannot
be added, removed, or shadowed locally.

`DIGEST_REF` uses the same bounded parser as an authored Experiment `digestRef`. It must contain one
exact lowercase `sha256` digest; mutable tags, bare digests, credentials, paths, and ambiguous
references are refused.

## Mutation rules

The first add publishes generation 1. Repeating the same name and subject is an idempotent
`changed:false` success. A different subject conflicts and never overwrites.

Removal requires the active entry digest from add or inspect. An exact compare-and-swap publishes a
generation-2 tombstone. Retrying with the original active digest is idempotent; every other token
conflicts. A tombstoned name cannot be reused or restored in v0alpha1.

`image remove` removes only the local name from future selection. It does not call Docker, remove
runtime image bytes, stop a workload, or delete an installed Experiment envelope. A retained
installed envelope remains inspectable because it binds the exact selected entry identity; a new or
exact-retry install using the tombstoned name fails its liveness check. Runtime image removal and
stored-artifact uninstall are separate future operations, and neither is implemented by this
command.

During `experiment install`, a selected local entry is rechecked after the fresh permit under the
stable shared catalog lock. The lock remains held through Experiment publication, so a concurrent
catalog removal cannot invalidate the selected entry mid-install. This proves naming liveness only;
it does not perform image acquisition or admission.

## Stored authority

The configured images component contains immutable entry and snapshot histories plus one current
pointer:

```text
images/catalog/
|-- current.json
|-- entries/<entry-digest>.json
`-- snapshots/<snapshot-digest>.json
```

Every read holds the stable catalog lock and verifies canonical schemas, record digests, the
reachable transition chain, all physical history, ownership and modes, fixed counts, and byte
bounds. Unsafe, missing initialized, changing, or corrupt authority returns `125`; an unknown or
removed logical name returns `1`.

The initialized-home receipt binds the catalog lock's device, inode, path, and schema. The lock
starts with its schema line and appends exactly one `initialized` line only after the first complete
staged catalog is durable and immediately before its no-replace commit. A matching bounded intent
distinguishes that pre-commit recovery window; replacement or any other bytes fail closed.

Mutations prepare one bounded intent beneath `images/.staging/`. A first catalog uses Linux
no-replace directory publication. Later changes durably publish immutable records before atomically
advancing and syncing the current pointer. The next mutation reconciles a recognized interrupted
intent against the observed pointer. After it proves that cleanup is safe, it durably renames the
operation to one bounded cleanup wrapper before removing any contents, so a crash during cleanup is
restartable. Unknown or unsafe residue is preserved and returns `125`.

This is tamper-evident state for a cooperative local account, not protection from a hostile process
running as the same user.
