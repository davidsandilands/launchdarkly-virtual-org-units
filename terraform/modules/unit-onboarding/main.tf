###############################################################################
# Onboarding one product area for one virtual organisational unit.
#
# OWNERSHIP: this module is applied by the UNIT, authenticating as an identity
# that holds only the unit-admin role from the catalogue. It creates projects,
# environments, teams and role assignments -- and it creates no roles, because
# the identity running it cannot.
#
# This is the whole point of the pattern: the unit onboards itself, repeatedly,
# with no ticket to the platform team, and the platform team's resources are not
# merely hidden from the run but absent from its permission surface.
###############################################################################

locals {
  # Derived, not supplied. An operator cannot fat-finger their way out of the
  # namespace, because the namespace is not an input.
  project_key = coalesce(var.project_key_override, "${var.unit_key}-${var.product_key}")

  leads_team_key = "${var.unit_key}-${var.product_key}-leads"
  devs_team_key  = "${var.unit_key}-${var.product_key}-devs"
}

###############################################################################
# Project and its standard environment set
#
# The unit runs the same two environments in every project. That uniformity is
# what allows a single authored role to serve every project in the unit: the
# developer role can name `env/development` literally because the environment
# key is a convention the unit controls.
###############################################################################

resource "launchdarkly_project" "this" {
  key  = local.project_key
  name = var.product_name
  tags = var.tags

  # `environments` is the complete, authoritative set: an environment absent from
  # this map is DELETED on apply, taking its SDK keys and all flag targeting with
  # it. Changing a map key destroys and recreates that environment.
  environments = {
    (var.nonprod_environment_key) = {
      name  = "Development"
      color = "3b82f6"
    }

    (var.prod_environment_key) = {
      name  = "Production"
      color = "ef4444"

      # Marking production critical and requiring comments are unit-level
      # decisions the unit admin can make for itself -- delegation that is real
      # rather than nominal.
      critical         = true
      require_comments = true
      confirm_changes  = true
    }
  }

  lifecycle {
    precondition {
      condition     = startswith(local.project_key, "${var.unit_key}-")
      error_message = <<-EOT
        Project key "${local.project_key}" is outside the "${var.unit_key}-" namespace.

        This precondition fails locally, before any API call. It is a convenience,
        not the control: the real enforcement is the createProject resource
        specifier on the unit-admin role, which rejects this at the API even if
        this check is removed. tests/boundary-tests.sh proves that.
      EOT
    }
  }
}

###############################################################################
# Teams and role assignment
#
# The role attribute is supplied HERE, at assignment time. The catalogue role was
# authored without knowing which project it would govern.
###############################################################################

data "launchdarkly_team_members" "leads" {
  count          = length(var.lead_member_emails) > 0 ? 1 : 0
  emails         = var.lead_member_emails
  ignore_missing = true
}

data "launchdarkly_team_members" "developers" {
  count          = length(var.developer_member_emails) > 0 ? 1 : 0
  emails         = var.developer_member_emails
  ignore_missing = true
}

resource "launchdarkly_team" "leads" {
  key         = local.leads_team_key
  name        = "${var.product_name} leads"
  description = "Lead developers for ${local.project_key}. Full flag lifecycle including production."

  custom_role_keys = [var.lead_developer_role_key]

  # Only populated when the catalogue is in role_attribute mode. Values are
  # free-form -- LaunchDarkly will not reject another unit's project key here --
  # so what makes a wrong value harmless is the deny guard inside the role itself,
  # not any validation at this point.
  #
  # VERIFIED CAVEAT: on an account without role attribute support this field is
  # accepted and silently discarded. Terraform records it in state and reports
  # success; the API stores nothing and the role resolves to no projects. Confirm
  # support before setting var.set_role_attributes.
  role_attributes = var.set_role_attributes ? {
    (var.role_attribute_name) = [launchdarkly_project.this.key]
  } : null

  # null, not [], when no emails are supplied. `[]` is an instruction to have NO
  # members, so Terraform would strip anyone added by an identity provider or by
  # hand on every apply. null leaves the attribute unmanaged and LaunchDarkly keeps
  # whatever is there. This is the "one membership authority" rule the variable
  # documentation describes, actually enforced.
  member_ids = length(var.lead_member_emails) > 0 ? data.launchdarkly_team_members.leads[0].team_members[*].id : null
}

resource "launchdarkly_team" "developers" {
  key         = local.devs_team_key
  name        = "${var.product_name} developers"
  description = "Developers for ${local.project_key}. Production targeting is request-only."

  custom_role_keys = [var.developer_role_key]

  role_attributes = var.set_role_attributes ? {
    (var.role_attribute_name) = [launchdarkly_project.this.key]
  } : null

  member_ids = length(var.developer_member_emails) > 0 ? data.launchdarkly_team_members.developers[0].team_members[*].id : null
}
