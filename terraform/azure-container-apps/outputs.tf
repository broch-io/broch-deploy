output "container_app_fqdn" {
  description = "Default *.azurecontainerapps.io hostname for the Container App. Useful for testing before the custom domain is bound."
  value       = azurerm_container_app.broch.latest_revision_fqdn
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
  description = "Postgres Flexible Server FQDN. Reachable from Azure services (firewall rule); add your client IP to the server firewall if you need to connect from elsewhere."
  value       = azurerm_postgresql_flexible_server.broch.fqdn
}

output "key_vault_name" {
  description = "Key Vault name. Rotate secrets via `az keyvault secret set`; restart the Container App to pick up new values."
  value       = azurerm_key_vault.broch.name
}
