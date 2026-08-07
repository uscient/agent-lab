package experiment

import (
	"list"
	"strings"
)

#Name: string & strings.MaxRunes(63) &
	=~"^[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$"

#DigestRef: string & strings.MinRunes(1) & strings.MaxRunes(255) &
	=~"^([a-z0-9]+([.-][a-z0-9]+)*(:(?:[1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5]))?/)?[a-z0-9]+([._-][a-z0-9]+)*(/[a-z0-9]+([._-][a-z0-9]+)*)*@sha256:[0-9a-f]{64}$"

#CatalogName: string & strings.MaxRunes(63) &
	=~"^[a-z][a-z0-9]*(?:-[a-z0-9]+)*\\.[a-z][a-z0-9]*(?:-[a-z0-9]+)*$"

#Image: close({digestRef: #DigestRef}) | close({catalogName: #CatalogName})

#Argument: string & strings.MaxRunes(1024) & !~"[\\p{Cc}\\p{Cf}\\p{Zl}\\p{Zp}]"

// A logical secret reference names material held elsewhere. It is deliberately
// not a filesystem path and deliberately cannot carry a value: the authored
// document is evidence, and evidence that can hold a secret will eventually
// hold one.
#SecretReference: string & strings.MaxRunes(191) &
	=~"^agent-lab\\.secret/[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$"

// Closed on purpose. `value:` and `path:` are rejected because the struct
// admits no field but these two, so inline material and host paths are refused
// by the shape rather than by a check somebody can forget to run.
#Secret: close({
	name:      #Name
	reference: #SecretReference
})

// A grant names a declared secret. It is a #Name, so a host path can never be
// spelled here either.
#Grant: #Name

#Member: close({
	name:  #Name
	image: #Image
	command: *[] | (list.MaxItems(64) & [...#Argument])
	resourceClass: *"small" | "standard"
	secretGrants:  *[] | (list.MaxItems(32) & list.UniqueItems() & [...#Grant])
})

#InstallAuthority: close({
	principal: #Name
	assurance: "declared"
	secrets:   list.MaxItems(32) & list.UniqueItems() & [...#Grant]
})

#Authority: close({
	install: #InstallAuthority
})

#Experiment: close({
	apiVersion: "agent-lab/v0alpha2"
	kind:       "Experiment"
	metadata: close({
		name: #Name
	})
	spec: close({
		secrets: *[] | (list.MaxItems(32) & [...#Secret])
		// Optional on purpose: a manifest that declares no install authority is
		// a legitimate document. It simply is not eligible to execute, and that
		// is a classification, not a validation failure. Defaulting a value here
		// would manufacture authority nobody authored.
		authority?: #Authority
		members:    list.MinItems(1) & list.MaxItems(16) & [...#Member]

		_secretNames: list.UniqueItems() & [for secret in secrets {secret.name}]
		_memberNames: list.UniqueItems() & [for member in members {member.name}]

		// Every grant, and every secret the install authority binds, must name a
		// secret this document declares. Unification against the declared set is
		// what makes an undeclared grant unrepresentable.
		_grantsDeclared: [for member in members for grant in member.secretGrants {
			grant & or(_secretNames)
		}]
		_authorityDeclared: [for name in [if authority != _|_ {authority.install.secrets}, []][0] {
			name & or(_secretNames)
		}]
	})
})
