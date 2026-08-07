package experiment

// A template leaves its grant set open as an unresolved alternative, so which
// authority the plan carries would be selected after publication.  Declared
// grants are immutable, so a non-concrete grant set is invalid input.
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
				secretGrants: ["broker-token"] | ["registry-pull"]
			},
		]
	}
}
