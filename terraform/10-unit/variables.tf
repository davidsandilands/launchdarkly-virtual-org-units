variable "unit_key" {
  description = "Namespace prefix of the unit running this configuration."
  type        = string
  default     = "brand-x"
}

variable "unit_name" {
  description = "Human-readable unit name, used only in resource names."
  type        = string
  default     = "Brand X"
}

variable "products" {
  description = <<-EOT
    The product areas this unit is onboarding. Adding an entry here is the entire
    onboarding process: a merge request against this file, reviewed by the unit,
    applied by the unit's pipeline.

    No platform-team involvement, and no role authored.
  EOT

  type = map(object({
    name                    = string
    tags                    = optional(list(string), [])
    lead_member_emails      = optional(list(string), [])
    developer_member_emails = optional(list(string), [])
  }))

  default = {
    "checkout" = {
      name = "Checkout"
      tags = ["owner-brand-x", "managed-by-unit"]
    }
    "search" = {
      name = "Search"
      tags = ["owner-brand-x", "managed-by-unit"]
    }
    "mobile" = {
      name = "Mobile app"
      tags = ["owner-brand-x", "managed-by-unit"]
    }
  }
}

variable "lead_developer_role_key" {
  description = <<-EOT
    Catalogue role attached to each product's leads team.

    Left as a naming convention rather than a remote state lookup on purpose: the
    unit's credential is not permitted to read the platform team's state, and the
    role keys are part of the published contract between them.
  EOT
  type        = string
  default     = null
}

variable "developer_role_key" {
  description = "Catalogue role attached to each product's developers team."
  type        = string
  default     = null
}

variable "role_attribute_name" {
  description = "Role attribute name the catalogue roles expect. Must match the catalogue."
  type        = string
  default     = "project"
}

variable "set_role_attributes" {
  description = <<-EOT
    Supply a role attribute value when attaching catalogue roles to teams.

    Defaults to true, matching the catalogue's default scoping_mode of
    "role_attribute". Set false only when the catalogue uses "namespace" scoping.

    Where an account does not support role attributes this is silently discarded and
    the roles grant nothing while Terraform reports success. Verify with
    tests/boundary-tests.sh section 9. See docs/06-verification-results.md.
  EOT
  type        = bool
  default     = true
}

variable "nonprod_environment_key" {
  description = "Non-production environment key. Must match what the catalogue roles name."
  type        = string
  default     = "development"
}

variable "prod_environment_key" {
  description = "Production environment key. Must match what the catalogue roles name."
  type        = string
  default     = "production"
}

variable "project_key_override" {
  description = <<-EOT
    ESCAPE HATCH FOR THE NEGATIVE TESTS. Leave null in normal use.

    Applies only when exactly one product is declared. Set it to a key outside the
    unit's namespace to watch the API refuse the creation:

      terraform apply -var 'project_key_override=brand-y-sneaky'
  EOT
  type        = string
  default     = null
}
