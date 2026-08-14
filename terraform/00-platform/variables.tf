variable "units" {
  description = <<-EOT
    The virtual organisational units to create role catalogues for.

    The map key is the namespace prefix. Two units are enough to demonstrate the
    pattern: one that we act as, and one whose resources must remain invisible.
  EOT

  type = map(object({
    name                      = string
    allow_destructive_actions = optional(bool, false)
    allow_token_minting       = optional(bool, false)

    # "role_attribute" (default) gives per-project isolation and is the mode the
    # deny guard exists for. "namespace" is the fallback for accounts where role
    # attributes do not take effect -- see docs/06-verification-results.md.
    scoping_mode = optional(string, "role_attribute")
  }))

  default = {
    "brand-x" = {
      name = "Brand X"
    }
    "brand-y" = {
      name = "Brand Y"
    }
  }
}

variable "create_unit_service_tokens" {
  description = <<-EOT
    Create one service token per unit, holding only that unit's admin role. This
    is the credential the unit's own pipeline authenticates with, and it is what
    makes the boundary demonstrable end to end.

    WARNING: a token created this way is stored in Terraform state in plaintext.
    For a throwaway demo account that is an acceptable trade for a one-command
    setup. For anything real, create the token in the UI against the same role and
    inject it into the pipeline's secret store instead.
  EOT
  type        = bool
  default     = true
}

variable "create_admin_teams" {
  description = <<-EOT
    Create a team per unit holding the unit-admin role, for the humans who
    administer the unit. Named inside the unit namespace so the unit can manage
    its own membership.
  EOT
  type        = bool
  default     = true
}

variable "acting_unit_key" {
  description = "The unit whose credential the demo and the tests act as. Must be a key in `units`."
  type        = string
  default     = "brand-x"
}

variable "other_unit_key" {
  description = <<-EOT
    The unit that must remain invisible to the acting unit. Must be a key in `units`.

    Note that this key appears nowhere in the acting unit's role policy. It is not
    on a deny list; it is simply never named, and is therefore denied by default.
    A deny list would have to be maintained forever as the other unit grows.
  EOT
  type        = string
  default     = "brand-y"
}

variable "seed_other_unit_project" {
  description = <<-EOT
    Create a project belonging to the second unit, as the platform team.

    This is the target of the isolation tests: something that demonstrably exists
    and that the first unit's credential must be unable to see, create in, or
    reach via a role attribute. Without it the negative tests prove nothing,
    because absence of a project is indistinguishable from absence of permission.
  EOT
  type        = bool
  default     = true
}
