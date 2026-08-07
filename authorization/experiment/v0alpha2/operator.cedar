@id("declared-lab-operator-install-v0alpha2")
permit (
  principal == AgentLab::Principal::"declared-lab-operator",
  action == AgentLab::Action::"experiment.install",
  resource is AgentLab::RequestedExperimentPlan
)
when
{
  !principal.authenticated &&
  principal.assurance == "declared" &&
  principal.source == "fixed-local-cli" &&
  context.bindingVersion == "v0alpha2" &&
  resource.planDigest == context.planDigest &&
  resource.sourceDigest == context.sourceDigest &&
  resource.contractDigest == context.contractDigest &&
  resource.contractVersion == "v0alpha2" &&
  resource.authorityDeclared &&
  resource.authorityPrincipal == "declared-lab-operator" &&
  resource.authorityAssurance == "declared" &&
  resource.boundSecrets.containsAll(resource.grantedSecrets)
};
