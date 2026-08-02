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

Both commands are previews. They create no durable Agent Lab state and do not invoke Docker or run
Experiment content. `authorize install` freshly checks the same held source and emits decision
evidence bound to its source, plan, contract, and authorization identities. The decision is not an
installation capability.

Each member selects either an exact digest-pinned OCI reference with `digestRef` or a shared name
with `catalogName`. Shared names have exactly two bounded lowercase components, `<vendor>.<image>`.
The `agent-lab.*` namespace belongs to the release-owned bundled catalog; the catalog is initially
empty. Other namespaces are reserved for the operator-local catalog introduced by the local image
catalog work. A name is resolved to an immutable subject before authorization. Catalog membership
is naming only, not image presence, admission, safety, or runnable status.
