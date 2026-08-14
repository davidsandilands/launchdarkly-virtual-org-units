###############################################################################
# STAGE 10 -- THE DELEGATED UNIT
#
# Applied by the unit, as often as it likes, with a credential that holds exactly
# one role: <unit_key>-unit-admin.
#
# Read this file as the answer to "what can a delegated unit actually do on its
# own?" It creates projects, environments, teams, and role assignments. It does
# not create roles, and it cannot name a resource outside its namespace.
###############################################################################

locals {
  # Role keys follow the catalogue's naming contract. Overridable, but the default
  # is what stage 00 produces.
  lead_developer_role_key = coalesce(var.lead_developer_role_key, "${var.unit_key}-lead-developer")
  developer_role_key      = coalesce(var.developer_role_key, "${var.unit_key}-developer")

  # The override is only coherent for a single product; with several it would
  # collide on the same key.
  single_product = length(var.products) == 1
}

check "override_is_used_sanely" {
  assert {
    condition     = var.project_key_override == null || local.single_product
    error_message = "project_key_override applies to a single product only; ${length(var.products)} are declared."
  }
}

module "product" {
  source   = "../modules/unit-onboarding"
  for_each = var.products

  unit_key     = var.unit_key
  product_key  = each.key
  product_name = "${var.unit_name} ${each.value.name}"
  tags         = each.value.tags

  lead_developer_role_key = local.lead_developer_role_key
  developer_role_key      = local.developer_role_key
  role_attribute_name     = var.role_attribute_name
  set_role_attributes     = var.set_role_attributes

  nonprod_environment_key = var.nonprod_environment_key
  prod_environment_key    = var.prod_environment_key

  lead_member_emails      = each.value.lead_member_emails
  developer_member_emails = each.value.developer_member_emails

  project_key_override = local.single_product ? var.project_key_override : null
}
