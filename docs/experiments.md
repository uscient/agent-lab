# Experiments

An Experiment is authored as data in a directory containing exactly one file, `experiment.cue`.
The file defines one concrete value named `experiment` in package `experiment`. Agent Lab snapshots
the exact bytes privately before evaluating them; extra entries, links, special files, suspicious
modes, changing sources, malformed CUE, and unknown schema fields are refused.

```cue
package experiment

experiment: {
	apiVersion: "agent-lab/v0alpha1"
	kind:       "Experiment"
	metadata: name: "example"
	spec: members: [{
		name: "worker"
		image: digestRef: "registry.example/team/worker@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
		command: ["serve"]
	}]
}
```

Check the artifact or preview its install authorization from the repository:

```bash
./scripts/agent-lab experiment check ./my-experiment
./scripts/agent-lab experiment authorize install ./my-experiment
```

These two commands are previews. They create no durable Agent Lab state and do not invoke Docker or
run Experiment content. `authorize install` freshly checks the same held source and emits decision
evidence bound to its source, plan, contract, and authorization identities. The decision is not an
installation capability.

Install a freshly checked and permitted artifact, then inspect its stored identity:

```bash
agent-lab [--home /absolute/private/home] experiment install ./my-experiment
agent-lab [--home /absolute/private/home] experiment inspect example
```

`install` takes one held source snapshot, derives the plan, and evaluates Cedar again in the same
operation without reopening the caller path. It does not accept a saved plan, decision, destination,
or name override. A permit is evidence for that exact candidate only; installation stores the
source, plan, decision, provenance, and receipt without running content, invoking Docker, acquiring
image bytes, or claiming runtime admission. The decision and receipt bind the same domain-separated
plan identity rather than an unframed hash of the JSON bytes.

An exact retry freshly validates and authorizes again, verifies the complete installed envelope,
and returns `changed:false` with the same `installationKey` and `receiptDigest`. The same requested
name with a different installation identity conflicts without overwrite. `inspect` is read-only: it
verifies and reports one installed identity, but never reconciles staging or repairs state. A later
effectful install may recover only recognized, bounded staging left by an interrupted publication;
unknown or ambiguous residue remains in place and returns infrastructure uncertainty.

All four commands work from a local installation after `agent-lab init` and explicit
`agent-lab tools provision`. Installed execution verifies and uses its release bundle and the
effective home's pinned tool cache; it does not depend on a source checkout.

Each member selects either an exact digest-pinned OCI reference with `digestRef` or a shared name
with `catalogName`. Shared names have exactly two bounded lowercase components, `<vendor>.<image>`.
The `agent-lab.*` namespace belongs to the release-owned bundled catalog; the catalog is initially
empty. Other valid namespaces belong to the operator-local catalog shared by every Experiment using
the same effective home:

```bash
agent-lab image add vendor.image registry.example/team/image@sha256:<64 lowercase hex>
agent-lab image inspect vendor.image
agent-lab image list [--all]
agent-lab image remove vendor.image --expect sha256:<entry digest>
```

Add records a mapping only. Same-subject add is idempotent; a different subject never overwrites.
Remove uses the active entry digest as a compare-and-swap token, creates a generation-two tombstone,
and makes the name non-reusable in v0. A local name is resolved from one held, verified catalog
snapshot. The plan binds only the selected entry digest, generation, and immutable subject; checked
evidence separately records the held snapshot revision and digest. An unrelated catalog change
therefore changes catalog evidence without changing the selected plan identity.

After a fresh install permit, every selected local entry is checked again under the stable shared
catalog lock. That lock remains held while the Experiment store lock is acquired and through durable
publication. Removal therefore cannot make the selected entry stale during installation. Direct
digest selectors and release-owned bundled names do not open the local catalog on this path.

Catalog membership is naming only, not image presence, admission, safety, or runnable status. See
[`images.md`](images.md) for the exact namespace, mutation, persistence, and failure contract.
