package experiment

// One declared reference names a host secret path instead of a bounded logical
// reference.  A closed authored schema must refuse it: a plan that can name a
// host path has already left the reference-only seam.
experiment: {
	apiVersion: "agent-lab/v0alpha2"
	kind:       "Experiment"
	metadata: name: "plan-authority"
	spec: {
		secrets: [
			{name: "broker-token", path: "/etc/agent-lab/broker-token"},
			{name: "registry-pull", reference: "agent-lab.secret/registry-pull"},
		]
		authority: install: {
			principal: "declared-lab-operator"
			assurance: "declared"
			secrets: ["broker-token", "registry-pull"]
		}
		members: [
			{
				name: "coordinator"
				image: digestRef: "registry.example/team/coordinator@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
				secretGrants: ["broker-token"]
			},
		]
	}
}
