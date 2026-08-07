package experiment

// An otherwise complete manifest carrying one unknown authored template field.
// The successor vocabulary is closed, so an unknown field is invalid input
// rather than a field to ignore.
experiment: {
	apiVersion: "agent-lab/v0alpha2"
	kind:       "Experiment"
	metadata: name: "plan-authority"
	spec: {
		secrets: [
			{name: "broker-token", reference: "agent-lab.secret/broker-token"},
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
				secretGrants: ["broker-token"]
				privileged: true
			},
		]
	}
}
