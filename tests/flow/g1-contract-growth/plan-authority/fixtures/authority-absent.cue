package experiment

// Structurally valid successor vocabulary with no declared install authority at
// all.  This is readable evidence, not an executable plan: the absence must be
// carried forward as a stable known denial rather than defaulted into authority
// nobody declared.
experiment: {
	apiVersion: "agent-lab/v0alpha2"
	kind:       "Experiment"
	metadata: name: "plan-authority"
	spec: {
		secrets: [
			{name: "broker-token", reference: "agent-lab.secret/broker-token"},
			{name: "registry-pull", reference: "agent-lab.secret/registry-pull"},
		]
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
