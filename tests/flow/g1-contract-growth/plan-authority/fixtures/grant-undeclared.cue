package experiment

// A template grants a logical name that no declared reference introduces.  A
// grant set that is not a subset of the declared references cannot be honoured
// without inventing authority, so the manifest is invalid input.
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
				secretGrants: ["broker-token", "admin-token"]
			},
		]
	}
}
