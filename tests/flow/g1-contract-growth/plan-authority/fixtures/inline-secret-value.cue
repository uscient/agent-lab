package experiment

// One declared reference carries an inline secret value.  The synthetic canary
// below is the only such value the suite ever creates; the closed authored
// schema must refuse this manifest before any plan is published, and no product
// diagnostic or evidence channel may echo the value back.
experiment: {
	apiVersion: "agent-lab/v0alpha2"
	kind:       "Experiment"
	metadata: name: "plan-authority"
	spec: {
		secrets: [
			{name: "broker-token", value: "G1CANARYSECRET4d9b21e7c6a05f38"},
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
