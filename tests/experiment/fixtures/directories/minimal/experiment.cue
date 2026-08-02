package experiment

experiment: {
	apiVersion: "agent-lab/v0alpha1"
	kind:       "Experiment"
	metadata: name: "first-experiment"
	spec: members: [{
		name: "coordinator"
		image: digestRef: "registry.example/team/coordinator@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
		command: ["serve"]
	}]
}
