# Without this, Terraform infers the provider source as hashicorp/launchdarkly
# for resources inside this module and the configuration will not initialise.
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    launchdarkly = {
      source  = "launchdarkly/launchdarkly"
      version = "~> 3.1"
    }
  }
}
