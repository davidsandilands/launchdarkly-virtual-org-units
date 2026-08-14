output "role_catalogue" {
  description = "Every role authored per unit. The agreed, auditable set of assignable roles."
  value = {
    for k, m in module.unit_roles : k => {
      namespace      = m.namespace_specifier
      unit_admin     = m.unit_admin_role_key
      lead_developer = m.lead_developer_role_key
      developer      = m.developer_role_key
      scoping_mode   = m.scoping_mode
      role_attribute = m.role_attribute_name
    }
  }
}

output "acting_unit" {
  description = "Values stage 10 and the tests need for the unit we act as."
  value = {
    unit_key                = var.acting_unit_key
    namespace               = module.unit_roles[var.acting_unit_key].namespace_specifier
    lead_developer_role_key = module.unit_roles[var.acting_unit_key].lead_developer_role_key
    developer_role_key      = module.unit_roles[var.acting_unit_key].developer_role_key
    scoping_mode            = module.unit_roles[var.acting_unit_key].scoping_mode
    role_attribute_name     = module.unit_roles[var.acting_unit_key].role_attribute_name
  }
}

output "isolation_target_project_key" {
  description = <<-EOT
    The other unit's project the test suite asserts is unreachable. Feed to
    tests/boundary-tests.sh as OTHER_PROJECT_KEY.
  EOT
  value       = try(launchdarkly_project.other_unit_seed[var.isolation_target].key, null)
}

output "other_unit_project_keys" {
  description = <<-EOT
    Every project belonging to the other unit. None of these should be visible to
    the acting unit's credential -- tests/boundary-tests.sh section 4 asserts that
    nothing outside the acting unit's namespace appears at all.
  EOT
  value       = sort([for p in launchdarkly_project.other_unit_seed : p.key])
}

output "unit_admin_team_keys" {
  description = "Teams holding each unit's admin role."
  value       = { for k, t in launchdarkly_team.unit_admins : k => t.key }
}

output "unit_automation_tokens" {
  description = <<-EOT
    Service tokens per unit, each capped at that unit's admin role.

    Read one with:
      terraform output -json unit_automation_tokens | jq -r '."brand-x"'
  EOT
  sensitive   = true
  value       = { for k, t in launchdarkly_access_token.unit_automation : k => t.token }
}

output "next_steps" {
  description = "What to run next."
  value       = <<-EOT

    Platform stage applied. The guardrails now exist; no unit resources do yet.

    1. Export the acting unit's delegated credential:

         export LD_UNIT_TOKEN=$(terraform output -json unit_automation_tokens \
           | jq -r '."${var.acting_unit_key}"')

    2. Onboard a product area AS THAT UNIT, from terraform/10-unit:

         cd ../10-unit
         LAUNCHDARKLY_ACCESS_TOKEN=$LD_UNIT_TOKEN terraform apply

    3. Prove the boundary:

         cd ../../tests && ./boundary-tests.sh

    Note what did NOT happen in step 2: no role was authored, and the platform
    team was not involved.
  EOT
}
