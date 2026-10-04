output "container_app_fqdn" {
  description = "Default *.azurecontainerapps.io hostname for the Container App. Useful for testing before the custom domain is bound."
  # The app-level hostname, not latest_revision_fqdn: a revision's hostname stops serving
  # once a later revision replaces it.
  value = azurerm_container_app.broch.ingress[0].fqdn
}

output "container_app_verification_id" {
  description = "Domain verification ID. Add this as a TXT record on `asuid.<wildcard_hostname>` BEFORE the custom domain binding will succeed."
  value       = azurerm_container_app_environment.broch.custom_domain_verification_id
}

output "broch_url" {
  description = "Public HTTPS URL for the Broch server (assuming you've bound the custom domain + provisioned the cert per the README)."
  value       = "https://${var.wildcard_hostname}"
}

output "postgres_fqdn" {
  description = "Postgres Flexible Server FQDN. It resolves and connects only from inside the module's private VNet (the server has no public endpoint); to administer it, use a VM or Cloud Shell attached to that VNet."
  value       = azurerm_postgresql_flexible_server.broch.fqdn
}

output "key_vault_name" {
  description = "Key Vault name. The app reads a pinned version of each secret, so rotate through Terraform: set the new value and run `terraform apply` twice (the first writes the new version, the second points the app at it), then restart the active revision. A direct `az keyvault secret set` is never picked up, and the next apply reverts it."
  value       = azurerm_key_vault.broch.name
}
