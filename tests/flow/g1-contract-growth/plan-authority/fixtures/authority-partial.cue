package experiment

// A declared install authority that binds only one of the two declared
// references, while a template still grants the unbound one.  Every authority
// field is present, so only a real binding check refuses this.
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
			secrets: ["broker-token"]
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
