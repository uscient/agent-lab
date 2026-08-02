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

#Member: close({
	name:  #Name
	image: #Image
	command: *[] | (list.MaxItems(64) & [...#Argument])
	resourceClass: *"small" | "standard"
})

#Experiment: close({
	apiVersion: "agent-lab/v0alpha1"
	kind:       "Experiment"
	metadata: close({
		name: #Name
	})
	spec: close({
		members: list.MinItems(1) & list.MaxItems(16) & [...#Member]
		_memberNames: list.UniqueItems() & [for member in members {member.name}]
	})
})
