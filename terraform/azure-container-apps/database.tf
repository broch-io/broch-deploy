# Azure Database for PostgreSQL Flexible Server, private: injected into the delegated subnet in
# network.tf with no public endpoint, so only the Container App (in the same VNet) can reach it.

resource "random_password" "postgres" {
  length  = 32
  special = false # avoid URL-encoding pain in the connection string
}

# BROCH_MASTER_KEY — customer-owned at-rest encryption root. Generated here and
# stored in Key Vault; required by the server at boot, never operator-supplied,
# never leaves your subscription. Rotating it forces a one-time re-auth (state
# self-heals).
resource "random_password" "master_key" {
  length  = 48
  special = false
}

# Accepted trivy findings (the ignore lines must sit directly above the resource):
#   AZU-0026 TLS: Flexible Server enforces TLS 1.2+ by default and Broch connects with
#            SSL Mode=VerifyFull; trivy's Flexible Server check doesn't read those settings.
#   AZU-0019 / AZU-0024 logging: left at Flexible Server defaults; tune them per install.
#   AZU-0021 connection_throttling exists only on Single Server, not Flexible Server.
# trivy:ignore:AZU-0026
# trivy:ignore:AZU-0019
# trivy:ignore:AZU-0024
# trivy:ignore:AZU-0021
resource "azurerm_postgresql_flexible_server" "broch" {
  name                = "${var.name_prefix}-postgres-${local.suffix}"
  resource_group_name = azurerm_resource_group.broch.name
  location            = azurerm_resource_group.broch.location
  version             = "16" # Pinned: moving to 17 is a major-version upgrade of an existing server

  administrator_login    = var.postgres_user
  administrator_password = random_password.postgres.result

  sku_name   = var.postgres_sku
  storage_mb = var.postgres_storage_mb

  backup_retention_days = 7

  # Private access only. A server's network mode is fixed at creation, so changing these
  # replaces the server.
  delegated_subnet_id           = azurerm_subnet.postgres.id
  private_dns_zone_id           = azurerm_private_dns_zone.postgres.id
  public_network_access_enabled = false

  # No zone redundancy / no high availability — cheapest tier.
  # For production, set `high_availability { mode = "ZoneRedundant" }`.

  lifecycle {
    # Avoid recreating on every apply if Azure picks a different zone.
    ignore_changes = [zone]
    # Guard against data loss: a destroy, or a change that replaces the server (such as the
    # network settings above), stops at plan instead of deleting the database. Before an
    # intentional destroy, delete this line (or set it to false) and run the command again.
    prevent_destroy = true
  }

  # The DNS zone must be linked to the VNet before the server is injected.
  depends_on = [azurerm_private_dns_zone_virtual_network_link.postgres]
}

resource "azurerm_postgresql_flexible_server_database" "broch" {
  name      = var.postgres_db_name
  server_id = azurerm_postgresql_flexible_server.broch.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# SSL Mode=VerifyFull: encrypted AND the server authenticated (certificate chain to the container's
# system trust store + hostname match on the server FQDN). SSL Mode=Require would only encrypt, so
# an on-path attacker could impersonate the server. Flexible Server certificates chain to public
# DigiCert / Microsoft roots, so no Root Certificate is needed.
resource "azurerm_key_vault_secret" "postgres_connection_string" {
  name         = "postgres-connection-string"
  value        = "Host=${azurerm_postgresql_flexible_server.broch.fqdn};Database=${var.postgres_db_name};Username=${var.postgres_user};Password=${random_password.postgres.result};SSL Mode=VerifyFull"
  key_vault_id = azurerm_key_vault.broch.id

  depends_on = [azurerm_role_assignment.kv_caller_admin]
}
