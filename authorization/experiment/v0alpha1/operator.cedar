@id("legacy-local-operator-install-v0")
permit (
  principal == AgentLab::Principal::"legacy-local-operator",
  action == AgentLab::Action::"experiment.install",
  resource is AgentLab::RequestedExperimentPlan
)
when
{
  !principal.authenticated &&
  principal.assurance == "none" &&
  principal.source == "fixed-local-cli" &&
  context.bindingVersion == "v0alpha1" &&
  resource.planDigest == context.planDigest &&
  resource.contractDigest == context.contractDigest &&
  resource.contractVersion == "v0alpha1"
};
