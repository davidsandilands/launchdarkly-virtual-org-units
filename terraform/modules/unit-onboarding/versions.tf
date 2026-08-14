terraform {
  required_version = ">= 1.5.0"

  required_providers {
    launchdarkly = {
      source  = "launchdarkly/launchdarkly"
      version = "~> 3.1"
    }
  }
}
