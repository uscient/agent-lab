package experiment

import "list"

manifest:       #Experiment
contractDigest: string & =~"^sha256:[0-9a-f]{64}$" @tag(contractDigest)

#Plan: close({
	apiVersion: "agent-lab.request/v0alpha1"
	kind:       "RequestedExperimentPlan"
	contract: close({
		digest:  contractDigest
		name:    "agent-lab.experiment"
		version: "v0alpha1"
	})
	metadata: close({
		requestedName: manifest.metadata.name
	})
	spec: close({
		members: [for member in list.Sort(manifest.spec.members, {
			x:    _
			y:    _
			less: x.name < y.name
		}) {
			name:          member.name
			image:         member.image
			command:       member.command
			resourceClass: member.resourceClass
		}]
	})
})
