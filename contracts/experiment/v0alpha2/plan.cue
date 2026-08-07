package experiment

import "list"

manifest:       #Experiment
contractDigest: string & =~"^sha256:[0-9a-f]{64}$" @tag(contractDigest)

// Every list is sorted on projection. Two authored documents that differ only
// in the order they happen to list secrets, grants, or members are the same
// request, and must produce byte-identical evidence -- otherwise the plan
// digest records authoring order rather than intent.
#Plan: close({
	apiVersion: "agent-lab.request/v0alpha2"
	kind:       "RequestedExperimentPlan"
	contract: close({
		digest:  contractDigest
		name:    "agent-lab.experiment"
		version: "v0alpha2"
	})
	metadata: close({
		requestedName: manifest.metadata.name
	})
	spec: close({
		secrets: [for secret in list.Sort(manifest.spec.secrets, {
			x:    _
			y:    _
			less: x.name < y.name
		}) {
			name:      secret.name
			reference: secret.reference
		}]

		// Present only when authored. A manifest that declares no install
		// authority projects without one; synthesizing an empty block here
		// would put authority in the evidence that nobody wrote.
		if manifest.spec.authority != _|_ {
			authority: close({
				install: close({
					principal: manifest.spec.authority.install.principal
					assurance: manifest.spec.authority.install.assurance
					secrets: [for name in list.Sort(manifest.spec.authority.install.secrets, list.Ascending) {
						name & or([for secret in manifest.spec.secrets {secret.name}])
					}]
				})
			})
		}

		members: [for member in list.Sort(manifest.spec.members, {
			x:    _
			y:    _
			less: x.name < y.name
		}) {
			name:              member.name
			requestedSelector: member.image
			command:           member.command
			resourceClass:     member.resourceClass
			// Unified against the declared set here, in the projected value.
			// The same rule lived in a hidden field before, and `cue export -e
			// #Plan` never referenced it, so it was never evaluated.
			secretGrants: [for grant in list.Sort(member.secretGrants, list.Ascending) {
				grant & or([for secret in manifest.spec.secrets {secret.name}])
			}]
		}]
	})
})
