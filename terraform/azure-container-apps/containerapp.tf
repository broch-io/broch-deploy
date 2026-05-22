# Container Apps Environment + Container App + managed identity + custom domain.

# ─── Environment ─────────────────────────────────────────────────────────────

resource "azurerm_container_app_environment" "broch" {
  name                       = "${var.name_prefix}-env"
  resource_group_name        = azurerm_resource_group.broch.name
  location                   = azurerm_resource_group.broch.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.broch.id
}

# ─── Managed identity ────────────────────────────────────────────────────────

resource "azurerm_user_assigned_identity" "broch" {
  name                = "${var.name_prefix}-app-identity"
  resource_group_name = azurerm_resource_group.broch.name
  location            = azurerm_resource_group.broch.location
}

# Container App's identity gets read-only access to the secrets it needs.
resource "azurerm_role_assignment" "app_kv_reader" {
  scope                = azurerm_key_vault.broch.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.broch.principal_id
}

# ─── Container App ───────────────────────────────────────────────────────────

resource "azurerm_container_app" "broch" {
  name                         = "${var.name_prefix}-app"
  container_app_environment_id = azurerm_container_app_environment.broch.id
  resource_group_name          = azurerm_resource_group.broch.name
  revision_mode                = "Single"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.broch.id]
  }

  # Pull credentials for the private GHCR image. Once the image is public,
  # delete this block + the github_pat var + the github_pat secret.
  registry {
    server               = "ghcr.io"
    username             = var.github_username
    password_secret_name = "ghcr-pat"
  }

  # Each Key Vault secret the container needs has to be re-declared here as
  # a Container Apps secret that points at the Key Vault entry by URI. The
  # `identity` field names the managed identity Container Apps uses to read.
  secret {
    name                = "ghcr-pat"
    key_vault_secret_id = azurerm_key_vault_secret.github_pat.id
    identity            = azurerm_user_assigned_identity.broch.id
  }

  secret {
    name                = "broch-license"
    key_vault_secret_id = azurerm_key_vault_secret.broch_license.id
    identity            = azurerm_user_assigned_identity.broch.id
  }

  secret {
    name                = "postgres-connection-string"
    key_vault_secret_id = azurerm_key_vault_secret.postgres_connection_string.id
    identity            = azurerm_user_assigned_identity.broch.id
  }

  ingress {
    external_enabled = true
    target_port      = 8080
    transport        = "auto"  # picks HTTP/2 + WebSocket support automatically

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 1
    max_replicas = 1   # no autoscaling for the example

    container {
      name   = "broch"
      image  = var.broch_image
      cpu    = var.container_cpu
      memory = var.container_memory

      env {
        name  = "ASPNETCORE_ENVIRONMENT"
        value = "Production"
      }
      env {
        name  = "ASPNETCORE_URLS"
        value = "http://0.0.0.0:8080"
      }
      env {
        name  = "API__WILDCARDHOSTNAME"
        value = var.wildcard_hostname
      }
      env {
        name  = "DATABASE__PROVIDER"
        value = "PostgreSQL"
      }
      env {
        name        = "BROCH_LICENSE"
        secret_name = "broch-license"
      }
      env {
        name        = "ConnectionStrings__DefaultConnection"
        secret_name = "postgres-connection-string"
      }

      liveness_probe {
        transport = "HTTP"
        path      = "/healthz"
        port      = 8080

        initial_delay           = 60
        interval_seconds        = 30
        timeout                 = 10
        failure_count_threshold = 3
      }

      readiness_probe {
        transport = "HTTP"
        path      = "/healthz"
        port      = 8080

        interval_seconds        = 10
        timeout                 = 5
        failure_count_threshold = 3
      }
    }
  }

  depends_on = [
    azurerm_role_assignment.app_kv_reader,
    azurerm_postgresql_flexible_server_firewall_rule.allow_azure,
  ]
}

# ─── Custom domains ──────────────────────────────────────────────────────────
#
# Container Apps' built-in managed certs handle the apex hostname fine but
# DON'T issue wildcards. So:
#   - The apex (tunnels.example.com) uses an Azure-managed cert
#   - The wildcard (*.tunnels.example.com) needs a cert you provision yourself
#     and upload to the environment
#
# Until you upload a wildcard cert, tunnel URLs will return cert errors. The
# README walks through the options (Front Door, manual cert upload, etc.).

resource "azurerm_container_app_custom_domain" "apex" {
  name             = var.wildcard_hostname
  container_app_id = azurerm_container_app.broch.id

  # certificate_binding_type + container_app_environment_certificate_id are
  # omitted on first apply; the cert is bound by hand after DNS validation
  # via `az containerapp hostname bind`. See README for the full sequence.

  lifecycle {
    ignore_changes = [certificate_binding_type, container_app_environment_certificate_id]
  }
}
