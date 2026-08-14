output "unit_key" {
  description = "The namespace prefix this catalogue was built for."
  value       = var.unit_key
}

output "namespace_specifier" {
  description = "The resource specifier glob that defines the unit's boundary."
  value       = "${var.unit_key}-*"
}

output "unit_admin_role_key" {
  description = "Role key for the delegated unit administrator."
  value       = launchdarkly_custom_role.unit_admin.key
}

output "lead_developer_role_key" {
  description = "Role key for the lead developer. Requires a project role attribute at assignment."
  value       = launchdarkly_custom_role.lead_developer.key
}

output "developer_role_key" {
  description = "Role key for the developer. Requires a project role attribute at assignment."
  value       = launchdarkly_custom_role.developer.key
}

output "scoping_mode" {
  description = "How the developer roles are scoped: \"namespace\" or \"role_attribute\"."
  value       = var.scoping_mode
}

output "role_attribute_name" {
  description = <<-EOT
    Name of the role attribute the developer roles expect at assignment time.
    Null in "namespace" mode, where the roles take no parameter and there is
    nothing to supply per team.
  EOT
  value       = var.scoping_mode == "role_attribute" ? var.role_attribute_name : null
}

output "assignable_role_keys" {
  description = <<-EOT
    Every role in this unit's catalogue. This list is the process control referred
    to in docs/04-enforced-vs-process.md: LaunchDarkly cannot restrict which roles
    a unit admin attaches to a unit team, so the catalogue is the agreed set and
    role-attachment events should be audited against it.
  EOT
  value = [
    launchdarkly_custom_role.unit_admin.key,
    launchdarkly_custom_role.lead_developer.key,
    launchdarkly_custom_role.developer.key,
  ]
}
