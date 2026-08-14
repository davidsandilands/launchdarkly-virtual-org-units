variable "unit_key" {
  description = "Namespace prefix of the virtual org unit doing the onboarding, e.g. \"brand-x\"."
  type        = string
}

variable "product_key" {
  description = <<-EOT
    Short key for the thing being onboarded, e.g. "checkout". The project key is
    derived as "<unit_key>-<product_key>", which is what keeps every onboarding
    inside the namespace by construction rather than by reviewer diligence.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]+(-[a-z0-9]+)*$", var.product_key))
    error_message = "product_key must be lowercase alphanumeric with single hyphens."
  }
}

variable "product_name" {
  description = "Human-readable name for the project."
  type        = string
}

variable "lead_developer_role_key" {
  description = "Catalogue role key to attach to the leads team. Authored by the platform team."
  type        = string
}

variable "developer_role_key" {
  description = "Catalogue role key to attach to the developers team. Authored by the platform team."
  type        = string
}

variable "role_attribute_name" {
  description = "Role attribute name the catalogue roles expect. Must match the catalogue."
  type        = string
  default     = "project"
}

variable "set_role_attributes" {
  description = <<-EOT
    Whether to supply a role attribute value when attaching catalogue roles.

    Defaults to false, matching the catalogue's default "namespace" scoping mode,
    where the roles take no parameter.

    Only set this true if the catalogue uses scoping_mode = "role_attribute" AND
    you have confirmed role attributes work in your account. On the account this
    repository was verified against they did not: the field was accepted and
    silently discarded, so the roles resolved to zero projects and granted
    nothing while Terraform reported success. Setting this true without that
    confirmation produces a delegation that looks correct and does nothing.
    See docs/06-verification-results.md.
  EOT
  type        = bool
  default     = false
}

variable "nonprod_environment_key" {
  description = "Key for the non-production environment. Must match the catalogue roles."
  type        = string
  default     = "development"
}

variable "prod_environment_key" {
  description = "Key for the production environment. Must match the catalogue roles."
  type        = string
  default     = "production"
}

variable "lead_member_emails" {
  description = <<-EOT
    Emails of existing account members to place in the leads team.

    Leave empty to create the team without members, which is the right choice when
    an identity provider owns membership. Only one system should be the authority
    on team membership: if SCIM or IdP-managed team sync populates a team, having
    Terraform also manage member_ids produces a fight that Terraform will keep
    trying to win on every apply.
  EOT
  type        = list(string)
  default     = []
}

variable "developer_member_emails" {
  description = "Emails of existing account members to place in the developers team. Same caveat as lead_member_emails."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = <<-EOT
    Tags applied to the project for inventory and reporting.

    Tags are NOT the boundary. They cannot gate creation, because a resource has
    no tags until after it exists, and anyone holding updateTags can move a
    resource across a tag-defined line. Use them to answer "what does this unit
    own", never to decide "may this unit touch it".
  EOT
  type        = list(string)
  default     = []
}

variable "project_key_override" {
  description = <<-EOT
    ESCAPE HATCH FOR THE NEGATIVE TESTS. Leave null in normal use.

    Setting this bypasses the derived "<unit_key>-<product_key>" key so you can
    deliberately attempt an out-of-namespace project creation and watch the
    LaunchDarkly API reject it. See tests/README.md.
  EOT
  type        = string
  default     = null
}
