# Applied by the UNIT, authenticating as its own delegated-admin service token.
#
#   export LAUNCHDARKLY_ACCESS_TOKEN=$LD_UNIT_TOKEN
#
# Run this with the org-admin token by mistake and the whole exercise is
# meaningless: everything will succeed, including the things that are supposed to
# fail. tests/boundary-tests.sh checks which identity it is holding before it
# asserts anything, for exactly this reason.
provider "launchdarkly" {
  archive_flags_on_destroy = true
}
