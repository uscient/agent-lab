package experiment

// The complete authored v0alpha2 plan-authority vocabulary: bounded logical
// secret references that never carry material, immutable per-template grants
// drawn only from those references, and a complete declared install authority.
experiment: {
	apiVersion: "agent-lab/v0alpha2"
	kind:       "Experiment"
	metadata: name: "plan-authority"
	spec: {
		secrets: [
			{name: "broker-token", reference: "agent-lab.secret/broker-token"},
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
				command: ["serve"]
				resourceClass: "standard"
				secretGrants: ["broker-token"]
			},
			{
				name: "hub"
				image: digestRef: "registry.example/team/hub@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
				secretGrants: ["broker-token", "registry-pull"]
			},
		]
	}
}
