package experiment

// The same declared authority as valid.cue with every ordered sequence written
// in the opposite source order and one non-semantic comment added.  A canonical
// projection must map this onto exactly the same requested plan; an echoing or
// fixture-fingerprinting implementation cannot.
experiment: {
	apiVersion: "agent-lab/v0alpha2"
	kind:       "Experiment"
	metadata: name: "plan-authority"
	spec: {
		members: [
			{
				// declared last here, first in valid.cue
				name: "hub"
				secretGrants: ["registry-pull", "broker-token"]
				image: digestRef: "registry.example/team/hub@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
			},
			{
				name: "coordinator"
				secretGrants: ["broker-token"]
				resourceClass: "standard"
				command: ["serve"]
				image: digestRef: "registry.example/team/coordinator@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
			},
		]
		authority: install: {
			secrets: ["registry-pull", "broker-token"]
			assurance: "declared"
			principal: "declared-lab-operator"
		}
		secrets: [
			{reference: "agent-lab.secret/registry-pull", name: "registry-pull"},
			{reference: "agent-lab.secret/broker-token", name: "broker-token"},
		]
	}
}
