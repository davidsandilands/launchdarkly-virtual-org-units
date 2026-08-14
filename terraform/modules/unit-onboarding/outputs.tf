output "project_key" {
  description = "Key of the project created for this product area."
  value       = launchdarkly_project.this.key
}

output "environment_keys" {
  description = "Environment keys in the project."
  value       = keys(launchdarkly_project.this.environments)
}

output "leads_team_key" {
  description = "Team key holding the lead developer role."
  value       = launchdarkly_team.leads.key
}

output "developers_team_key" {
  description = "Team key holding the developer role."
  value       = launchdarkly_team.developers.key
}

output "role_attribute_value" {
  description = "The project key supplied as the role attribute value to both teams."
  value       = launchdarkly_project.this.key
}
