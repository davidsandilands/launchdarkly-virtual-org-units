###############################################################################
# STAGE 00 -- PLATFORM TEAM
#
# Applied once, by the team that owns the LaunchDarkly account, using an
# org-admin identity. Everything created here is a guardrail: the role
# catalogues, the identities that hold them, and one project belonging to the
# other unit so that isolation can be tested against something real.
#
# Nothing in this stage is re-run when a unit onboards a new team. That is the
# measure of whether the delegation is real.
###############################################################################

check "units_are_declared" {
  assert {
    condition = alltrue([
      for k in [var.acting_unit_key, var.other_unit_key] : contains(keys(var.units), k)
    ])
    error_message = <<-EOT
      acting_unit_key ("${var.acting_unit_key}") and other_unit_key ("${var.other_unit_key}")
      must both be keys in var.units. Declared units: ${join(", ", keys(var.units))}.
    EOT
  }
}

check "units_are_distinct" {
  assert {
    condition     = var.acting_unit_key != var.other_unit_key
    error_message = <<-EOT
      acting_unit_key and other_unit_key are the same ("${var.acting_unit_key}").
      The isolation tests would then be asserting that the unit cannot see itself,
      which will fail for the wrong reason.
    EOT
  }
}

###############################################################################
# Role catalogues -- one per unit
#
# The same module, applied twice. This is the part that makes the pattern a
# pattern: onboarding a third unit is one map entry, not a redesign.
###############################################################################

module "unit_roles" {
  source   = "../modules/unit-role-catalogue"
  for_each = var.units

  unit_key  = each.key
  unit_name = each.value.name

  scoping_mode              = each.value.scoping_mode
  allow_destructive_actions = each.value.allow_destructive_actions
  allow_token_minting       = each.value.allow_token_minting
}

###############################################################################
# Unit admin teams
#
# Keyed inside the unit namespace so that the unit admin role can manage its own
# membership. Created empty: add real account members via
# `member_emails` in tfvars, or let an identity provider populate them.
###############################################################################

resource "launchdarkly_team" "unit_admins" {
  for_each = var.create_admin_teams ? var.units : {}

  key         = "${each.key}-admins"
  name        = "${each.value.name} :: unit admins"
  description = "Delegated administrators for the ${each.key}-* namespace."

  custom_role_keys = [module.unit_roles[each.key].unit_admin_role_key]

  # No role_attributes: the unit admin role is scoped by the namespace glob and
  # takes no parameter. Only the developer roles are parameterised.
}

###############################################################################
# Unit automation credentials
#
# The token that stage 10 authenticates with. Its permissions are capped at the
# permissions of this role at the moment of creation and are then fixed, so no
# later widening of the catalogue reaches an already-issued token, and no token
# minted downstream by the unit can exceed it.
###############################################################################

resource "launchdarkly_access_token" "unit_automation" {
  for_each = var.create_unit_service_tokens ? var.units : {}

  name          = "${each.value.name} unit automation (delegated admin)"
  service_token = true

  # Role keys, not IDs, despite the field name.
  custom_roles = [module.unit_roles[each.key].unit_admin_role_key]
}

###############################################################################
# A project belonging to the other unit
#
# The control in the experiment. It exists, it is populated, and the acting
# unit's credential must not be able to see it, write to it, or reach it by
# supplying its key as a role attribute value.
###############################################################################

resource "launchdarkly_project" "other_unit_seed" {
  count = var.seed_other_unit_project ? 1 : 0

  key  = "${var.other_unit_key}-payments"
  name = "${var.units[var.other_unit_key].name} payments"

  # Tags for inventory only. They are deliberately not referenced by any policy
  # in this repository.
  tags = ["owner-${var.other_unit_key}", "managed-by-platform"]

  environments = {
    development = {
      name  = "Development"
      color = "3b82f6"
    }
    production = {
      name     = "Production"
      color    = "ef4444"
      critical = true
    }
  }
}
