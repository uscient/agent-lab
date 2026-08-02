# Experiments

Experiments are Agent Lab's v0alpha1 format for accepting a declarative workload description as
data. Agent Lab snapshots the authored bytes, validates them with the release-pinned CUE contract,
resolves image selectors to immutable OCI subjects, evaluates the release-pinned Cedar install
policy, and, only on a permit, can retain the resulting evidence in a private local home.

> **Current boundary:** Experiment onboarding does not run source, invoke Docker, contact an image
> registry, acquire or admit image bytes, create a network, or start a workload. Start, stop,
> runtime removal, and stored-artifact uninstall are not implemented.

The supported v0alpha1 host is Linux. Experiment installation and public Git intake require Linux;
local image-catalog mutations do as well. A policy `permit` is evidence for one exact candidate under
the current fixed local compatibility principal. It is not user authentication, human approval,
image admission, or a reusable installation capability.

## Try the onboarding lifecycle

This checkout-local walkthrough creates a disposable CLI prefix and Agent Lab home, then exercises
the complete supported directory-source onboarding path against the inert test fixture. A cold tool
cache requires network access for the explicit provisioning step.

```bash
(
set -euo pipefail

experiment_demo_root="$(mktemp -d)"
experiment_cli="$experiment_demo_root/prefix/bin/agent-lab"

./scripts/install-local --prefix "$experiment_demo_root/prefix"
"$experiment_cli" --home "$experiment_demo_root/home" init
"$experiment_cli" --home "$experiment_demo_root/home" config check
"$experiment_cli" --home "$experiment_demo_root/home" tools provision

"$experiment_cli" --home "$experiment_demo_root/home" \
  experiment check tests/experiment/fixtures/directories/minimal
"$experiment_cli" --home "$experiment_demo_root/home" \
  experiment authorize install tests/experiment/fixtures/directories/minimal
"$experiment_cli" --home "$experiment_demo_root/home" \
  experiment install tests/experiment/fixtures/directories/minimal
"$experiment_cli" --home "$experiment_demo_root/home" \
  experiment inspect first-experiment

printf 'Demo state: %s\n' "$experiment_demo_root"
)
```

`tools provision` is the only command in this sequence that downloads tools. It acquires and
verifies the pinned CUE and Cedar releases. The remaining commands do not contact Docker or the
fixture's example registry. The final line prints the retained disposable state location.
The walkthrough intentionally leaves that isolated directory in place for inspection. Because the
retained records are read-only and no uninstall command exists, cleanup is an explicit host action.

For persistent use, follow [Local installation](installation.md) to install the CLI, put its `bin`
directory on `PATH`, initialize an explicit private home, and provision the tools once. Normal
Experiment commands never download missing tools automatically.

## Lifecycle and effects

```text
directory | bounded ZIP | exact public Git commit
                  -> private source snapshot
                  -> pinned CUE validation and immutable image resolution
                  -> fresh Cedar install decision
                  -> on permit, closed local evidence envelope
```

Each source-taking command snapshots its own source; output from one command is never authority for
the next.

| Stage | Command | Durable effect |
|---|---|---|
| Check | `experiment check` | none; emits source, plan, and applicable catalog evidence |
| Authorize preview | `experiment authorize install` | none; emits a fresh source- and plan-bound Cedar decision |
| Install | `experiment install` | freshly repeats check and authorization, then retains a closed evidence envelope only on permit |
| Inspect | `experiment inspect NAME` | none; verifies and reports one retained envelope without repair |

The preview forms do not create durable Agent Lab state or execute Experiment content. Public Git
previews do perform the bounded network acquisition described under [Public Git](#public-git).

## Author an Experiment

A directory source contains exactly one file named `experiment.cue`. The file uses package
`experiment` and defines one concrete value named `experiment`:

```cue
package experiment

experiment: {
	apiVersion: "agent-lab/v0alpha1"
	kind:       "Experiment"
	metadata: name: "example"
	spec: members: [{
		name: "worker"
		image: digestRef: "registry.example/team/worker@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
		command: ["serve"]
	}]
}
```

The schema is closed: unknown fields, incomplete values, mutable image references, duplicate member
names, and unsupported values are rejected.

| Field | Contract |
|---|---|
| `apiVersion` | exactly `agent-lab/v0alpha1` |
| `kind` | exactly `Experiment` |
| `metadata.name` | 1–63 lowercase ASCII letters, digits, or hyphens; starts with a letter and ends with a letter or digit |
| `spec.members` | 1–16 members with unique names |
| `members[].name` | same bounded name grammar as the Experiment |
| `members[].image` | exactly one `digestRef` or `catalogName` selector |
| `members[].command` | optional; defaults to empty; at most 64 arguments of at most 1,024 characters without control, format, line-separator, or paragraph-separator characters |
| `members[].resourceClass` | optional; `small` by default, or `standard` |

An Experiment supplies data only. It cannot select a contract, policy, principal, tool, catalog
path or mapping, source destination, concrete host resource limit, or runtime authority. Image
selection is limited to the two closed forms described below.

## Check and authorize

The installed CLI syntax for a directory source is:

```text
agent-lab --home ABSOLUTE_HOME experiment check SOURCE_DIRECTORY
agent-lab --home ABSOLUTE_HOME experiment authorize install SOURCE_DIRECTORY
```

Replace the uppercase placeholders; they are notation, not literal shell arguments. `check` emits
canonical JSON containing the exact source identity and resolved `RequestedExperimentPlan`.
`authorize install` independently snapshots and plans the source, then emits the Cedar decision
bound to the source, plan, contract, and authorization identities.

The current policy uses the fixed unauthenticated local compatibility principal
`legacy-local-operator` with assurance `none`. A valid JSON deny decision returns status 1. Neither
a permit nor a prior check result can be passed to `install`; installation obtains a fresh decision
in the same process that holds the source snapshot. A denied install retains no Experiment state.

## Install and inspect

The installed CLI syntax is:

```text
agent-lab --home ABSOLUTE_HOME experiment install SOURCE_DIRECTORY
agent-lab --home ABSOLUTE_HOME experiment inspect EXPERIMENT_NAME
```

`install` takes one held source snapshot, derives and resolves the plan, and evaluates Cedar again.
Only a permit publishes the artifact, plan, decision, provenance, and receipt without replacement.
It accepts no saved plan, saved decision, destination, or name override. See
[Installed Experiment evidence](installation.md#installed-experiment-evidence) for the stored layout
and verification rules.

An exact retry freshly validates and authorizes again, verifies the complete installed envelope,
and returns `changed:false` with the same `installationKey` and `receiptDigest`. The same requested
name with a different installation identity conflicts without overwrite. `inspect` is read-only and
does not reconcile staging or repair state.

There is currently no Experiment list, update, delete, or uninstall command. Release garbage
collection and in-place home-layout migration are also not implemented. Stored state is
tamper-evident for a cooperative local account, not immutable against another process running as
that same user.

## Source formats

The lifecycle commands accept three source forms. The forms below are syntax notation; replace the
uppercase placeholders.

| Source | Argument form |
|---|---|
| Directory | `SOURCE_DIRECTORY` |
| ZIP | `--zip ARCHIVE` |
| Public Git | `--git https://github.com/OWNER/REPOSITORY.git --commit COMMIT_ID` |

For example, each form can be checked with:

```text
agent-lab --home ABSOLUTE_HOME experiment check SOURCE_DIRECTORY
agent-lab --home ABSOLUTE_HOME experiment check --zip ARCHIVE
agent-lab --home ABSOLUTE_HOME experiment check --git https://github.com/OWNER/REPOSITORY.git --commit COMMIT_ID
```

Use the same source form after `authorize install` or `install`.

### Directory

The source must be one stable, non-symlink directory containing only `experiment.cue`. The authored
file must be a regular non-symlink with one hard link, no executable bit, no group/world write bit,
and at most 262,144 bytes. Agent Lab refuses identity or content changes observed while it takes the
private snapshot.

### ZIP

The archive must be one stable regular file of at most 1,048,576 bytes. It may contain only the
exact member `experiment.cue`, stored or deflated, expanding to at most 262,144 bytes. Agent Lab
rejects ZIP64, multiple disks, encryption, comments, extra fields, alternate paths, extra members,
special types, inconsistent headers, invalid checksums or lengths, truncated streams, and trailing
bytes before CUE evaluation. It never extracts the archive or accepts a caller-selected destination.
Member type metadata is accepted only when a regular file can be proved for Unix or DOS-compatible
FAT, NTFS, and VFAT creator systems; other creator systems fail closed.

ZIP provenance records the raw archive size and SHA-256 digest. The normalized source identity is
still derived from the authored `experiment.cue` bytes, so equivalent directory and ZIP sources
converge on the same source and plan identities.

### Public Git

Git intake is Linux-only. It accepts one normalized unauthenticated
`https://github.com/OWNER/REPOSITORY.git` URL and one exact lowercase 40-hex SHA-1 commit object ID.
The commit's root tree must contain only the mode-`100644` regular blob `experiment.cue`.

A fixed credential-free GitHub Git Data API client reads the commit, tree, and blob under one
five-second deadline and a 1,048,576-byte aggregate response cap. The response must echo the
requested commit; Agent Lab independently recomputes the returned tree and blob Git object IDs.
Redirects, credentials, mutable refs, alternate protocols or authorities, extra tree entries, and
changed bound objects fail closed.

Git acquisition does not invoke Git, create a repository, check out content, follow submodules, or
execute repository data. The fixed acquisition worker creates no temporary files; the common CUE
planning path evaluates the held snapshot in its private temporary workspace. Identical authored
bytes converge on the same source and plan identities across directory, ZIP, and Git; transport
provenance remains distinct.

## Select images

Each member selects exactly one image form:

- `digestRef`: an immutable OCI reference ending in one lowercase `sha256` digest;
- `catalogName`: one bounded lowercase `<vendor>.<image>` name resolved to an immutable subject.

The `agent-lab.*` namespace is release-owned; its bundled catalog is currently empty. Other valid
names are operator-owned within one initialized Agent Lab home. Use the [Local image names](images.md)
guide to add, inspect, list, or remove those mappings.

A catalog mapping is naming metadata only. It does not contact a registry, acquire or inspect image
bytes, prove that an image is runnable, or perform admission. Installation rechecks a selected local
entry under the catalog lock and holds that authority through publication; an installed plan never
re-resolves the name.

## Result meanings

| Exit | Meaning |
|---|---|
| `0` | the command completed successfully; authorization status 0 means permit |
| `1` | stable invalid input, denial, conflict, or not-found result |
| `2` | invalid command usage |
| `125` | acquisition, trusted input, tool, filesystem, lock, publication, or cleanup uncertainty |
| `128 + signal` | a managed subprocess path was terminated by a signal |

Status 125 is not a rejection or a successful security decision. Diagnose the missing or uncertain
infrastructure; do not reinterpret it as a deny or bypass the failed control.

## Related documentation

- [Local installation](installation.md): CLI bundle, private home, tool provisioning, and evidence
  layout
- [Local image names](images.md): catalog names, immutable subjects, mutation rules, and stored
  authority
- [Architecture](architecture.md#experiment-planning-and-installed-evidence): trust flow and
  control-plane boundaries
- [Security](../SECURITY.md) and [threat model](../THREAT_MODEL.md): formal hard stops, assumptions,
  and residual risk
