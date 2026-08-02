# Local image names

Agent Lab can assign one operator-local name to an already immutable OCI subject:

```bash
agent-lab [--home ABSOLUTE_HOME] image add VENDOR.IMAGE DIGEST_REF
agent-lab [--home ABSOLUTE_HOME] image inspect VENDOR.IMAGE
agent-lab [--home ABSOLUTE_HOME] image list [--all]
agent-lab [--home ABSOLUTE_HOME] image remove VENDOR.IMAGE --expect ENTRY_DIGEST
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

Mutations prepare one bounded intent beneath `images/.staging/`. A first catalog uses Linux
no-replace directory publication. Later changes durably publish immutable records before atomically
advancing and syncing the current pointer. The next mutation reconciles a recognized interrupted
intent against the observed pointer; unknown residue is preserved and returns `125`.

This is tamper-evident state for a cooperative local account, not protection from a hostile process
running as the same user.

