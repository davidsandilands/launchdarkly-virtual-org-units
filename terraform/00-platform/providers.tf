# Applied by the PLATFORM TEAM with an org-admin identity.
#
# Supply the token via the environment, not this file:
#   export LAUNCHDARKLY_ACCESS_TOKEN=api-xxxxxxxx
provider "launchdarkly" {
  # Safety net for a demo account: if a project is removed from configuration,
  # archive its flags rather than deleting them outright.
  archive_flags_on_destroy = true
}
