# Azure Database for PostgreSQL Flexible Server.
#
# Public-access mode with the Container Apps environment's outbound IP
# whitelisted is simpler than the VNet-integration path, especially for a
# starting example. For a private setup, add `delegated_subnet_id` +
# `private_dns_zone_id` and remove the firewall rule.

resource "random_password" "postgres" {
  length  = 32
  special = false  # avoid URL-encoding pain in the connection string
}

resource "azurerm_postgresql_flexible_server" "broch" {
  name                = "${var.name_prefix}-postgres-${local.suffix}"
  resource_group_name = azurerm_resource_group.broch.name
  location            = azurerm_resource_group.broch.location
  version             = "16"  # Azure's Flexible Server doesn't support 17 yet (as of provider 4.10)

  administrator_login    = var.postgres_user
  administrator_password = random_password.postgres.result

  sku_name   = var.postgres_sku
  storage_mb = var.postgres_storage_mb

  backup_retention_days = 7

  # No zone redundancy / no high availability — cheapest tier.
  # For production, set `high_availability { mode = "ZoneRedundant" }`.

  lifecycle {
    # Avoid recreating on every apply if Azure picks a different zone.
    ignore_changes = [zone]
  }
}

resource "azurerm_postgresql_flexible_server_database" "broch" {
  name      = var.postgres_db_name
  server_id = azurerm_postgresql_flexible_server.broch.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# Allow any Azure-hosted resource to reach the DB. Container Apps egress IPs
# can change, so the narrow "just our app's outbound IP" approach is fragile.
# This is the trade-off; the VNet path fixes it but adds setup cost.
resource "azurerm_postgresql_flexible_server_firewall_rule" "allow_azure" {
  name             = "AllowAzureServices"
  server_id        = azurerm_postgresql_flexible_server.broch.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

resource "azurerm_key_vault_secret" "postgres_connection_string" {
  name         = "postgres-connection-string"
  value        = "Host=${azurerm_postgresql_flexible_server.broch.fqdn};Database=${var.postgres_db_name};Username=${var.postgres_user};Password=${random_password.postgres.result};Ssl Mode=Require"
  key_vault_id = azurerm_key_vault.broch.id

  depends_on = [azurerm_role_assignment.kv_caller_admin]
}
