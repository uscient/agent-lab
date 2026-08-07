package experiment

// A template grants a host path rather than a declared logical name.  Grants
// name references; they never name host material.
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
				secretGrants: ["/etc/agent-lab/broker-token"]
			},
		]
	}
}
