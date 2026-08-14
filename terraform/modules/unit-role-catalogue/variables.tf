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

    "role_attribute" (DEFAULT): the roles name proj/$${roleAttribute/<name>} and the
    project is supplied per team when the role is assigned. One authored role serves
    every project the unit will ever create, AND each team is confined to its own
    project. This is the mode the deny guard exists for, and the reason the guard is
    the central control in this design rather than a nicety: nothing constrains
    which value a unit admin supplies, so the guard is what makes a wrong one
    harmless.

    "namespace": the roles name the unit's key glob directly, e.g. proj/brand-x-*.
    One fewer moving part, and nothing to misconfigure at assignment time. Trade-off:
    a developer can act on EVERY project in the unit, not just the one their team
    owns, so there is no isolation between projects inside a unit. Note that in this
    mode the deny guard becomes belt-and-braces rather than load-bearing, because
    there is no attribute value to get wrong.

    ACCOUNT SUPPORT: role attributes did not persist on the account this repository
    was verified against -- POST /teams accepted and discarded the field,
    updateRoleAttribute returned 200 without saving, replaceRoleAttributes returned
    400 "unknown field", and the member object had no roleAttributes key at all.
    LaunchDarkly documents no gate beyond Enterprise, and Enterprise custom roles
    work on that account, so this may be a product issue rather than a plan one.

    Confirm with tests/boundary-tests.sh section 9, which asserts the deployed role
    resolves to exactly one project. If it reports zero, role attributes are not
    taking effect in your account and "namespace" is the working fallback.
    See docs/06-verification-results.md.
  EOT
  type        = string
  default     = "role_attribute"

  validation {
    condition     = contains(["namespace", "role_attribute"], var.scoping_mode)
    error_message = "scoping_mode must be \"namespace\" or \"role_attribute\"."
  }
}

variable "role_attribute_name" {
  description = <<-EOT
    Name of the role attribute that parameterises the developer roles by project.
    Referenced in policies as $${roleAttribute/<name>} and supplied per team at
    assignment time. Ignored when scoping_mode is "namespace".

    The name must match exactly between the role policy and the value supplied at
    assignment. A mismatch is silent: the role resolves to nothing.
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
