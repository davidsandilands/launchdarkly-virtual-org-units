output "onboarded" {
  description = "What this unit provisioned for itself."
  value = {
    for k, m in module.product : k => {
      project_key     = m.project_key
      environments    = m.environment_keys
      leads_team      = m.leads_team_key
      developers_team = m.developers_team_key
      role_attribute  = m.role_attribute_value
    }
  }
}

output "roles_authored_by_this_stage" {
  description = <<-EOT
    Deliberately empty, and the most important output in the repository.

    The unit assigned two roles and authored neither. `createRole` is absent from
    the unit-admin policy because the content of a role cannot be constrained by
    the permission to create one -- see docs/04-enforced-vs-process.md.
  EOT
  value       = []
}
