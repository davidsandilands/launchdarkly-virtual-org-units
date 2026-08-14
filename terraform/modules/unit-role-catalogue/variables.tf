variable "unit_key" {
  description = <<-EOT
    The key prefix that defines this virtual organisational unit. Every project,
    team and role belonging to the unit must start with this string followed by
    a hyphen. This prefix IS the security boundary -- see docs/02-the-boundary-model.md.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]+(-[a-z0-9]+)*$", var.unit_key))
    error_message = "unit_key must be lowercase alphanumeric with single hyphens, e.g. \"brand-x\"."
  }
}

variable "unit_name" {
  description = "Human-readable name of the unit, used in role display names."
  type        = string
}

variable "scoping_mode" {
  description = <<-EOT
    How the developer roles are scoped to projects.

    "namespace" (default, VERIFIED WORKING): the developer roles name the unit's
    key glob directly, e.g. proj/brand-x-*. One authored role covers every project
    the unit will ever create. Trade-off: a developer can act on ALL projects in
    the unit, not just the one their team owns. The unit is the boundary, not the
    project.

    "role_attribute" (REQUIRES ACCOUNT SUPPORT): the roles name
    proj/$${roleAttribute/<name>} and the project is supplied per team at
    assignment time, giving per-project isolation inside the unit.

    Role attributes were NOT available on the account this repository was verified
    against: POST /teams silently dropped the field, the updateRoleAttribute
    instruction returned 200 without persisting, replaceRoleAttributes returned
    400 "unknown field", and roleAttributes was absent from the member schema
    entirely. Confirm the feature is present in your account before choosing this
    mode, or the developer roles will resolve to no projects and grant nothing.
    See docs/06-verification-results.md.
  EOT
  type        = string
  default     = "namespace"

  validation {
    condition     = contains(["namespace", "role_attribute"], var.scoping_mode)
    error_message = "scoping_mode must be \"namespace\" or \"role_attribute\"."
  }
}

variable "role_attribute_name" {
  description = <<-EOT
    Name of the role attribute used to parameterise the developer roles by project,
    when scoping_mode is "role_attribute". Referenced in policies as
    $${roleAttribute/<name>} and supplied at assignment time. Ignored in
    "namespace" mode.
  EOT
  type        = string
  default     = "project"
}

variable "nonprod_environment_key" {
  description = <<-EOT
    Environment key in which a plain developer may change flag targeting. The unit
    is assumed to run a standard environment set across all of its projects; that
    assumption is what lets a single role serve every project in the unit.
  EOT
  type        = string
  default     = "development"
}

variable "prod_environment_key" {
  description = "Environment key treated as production: request-only for plain developers."
  type        = string
  default     = "production"
}

variable "allow_destructive_actions" {
  description = <<-EOT
    Whether the unit admin role may delete projects, environments and teams.

    Defaults to false. Terraform is declarative and therefore destructive: a
    removed resource block, a changed project key, or a stray `terraform destroy`
    will attempt deletion. Withholding the delete actions means the platform team,
    not the unit's pipeline, is the last line of defence against that.
  EOT
  type        = bool
  default     = false
}

variable "allow_token_minting" {
  description = <<-EOT
    Whether the unit admin role may create and manage service tokens.

    A service token can never hold more permission than the identity that created
    it, and its permissions are fixed at creation. That makes delegated token
    minting structurally safe with respect to the namespace boundary. It is off by
    default here only because token lifecycle (rotation, expiry) is a separate
    operational commitment -- see docs/04-enforced-vs-process.md.
  EOT
  type        = bool
  default     = false
}
