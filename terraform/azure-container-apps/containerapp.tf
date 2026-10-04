# Container Apps Environment + Container App + managed identity + custom domain.

# ─── Environment ─────────────────────────────────────────────────────────────

# logs_destination is explicit because azurerm 5 no longer infers it: without
# "log-analytics" the provider rejects log_analytics_workspace_id at plan time.
resource "azurerm_container_app_environment" "broch" {
  name                       = "${var.name_prefix}-env"
  resource_group_name        = azurerm_resource_group.broch.name
  location                   = azurerm_resource_group.broch.location
  logs_destination           = "log-analytics"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.broch.id

  # Joined to the private VNet (network.tf) so the app reaches the database, which has no public
  # endpoint. Ingress stays public: internal_load_balancer_enabled is left false. The VNet and
  # workload profile are fixed at creation; changing them replaces the environment.
  infrastructure_subnet_id = azurerm_subnet.aca.id
  # Named explicitly: left unset, Azure picks an ME_... name the provider doesn't read back.
  # Azure deletes this group some time after the environment, so the random suffix keeps a
  # destroy-and-reapply from asking for a group that is still being deleted.
  infrastructure_resource_group_name = "${azurerm_resource_group.broch.name}-aca-infra-${local.suffix}"

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
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

locals {
  # The plain settings Broch reads (the secrets are Key Vault references on the container). One
  # map so the configuration contract check (scripts/config-contract.py) can render exactly what this
  # module sends and ask Broch whether it would start with it.
  broch_environment = {
    ASPNETCORE_ENVIRONMENT     = "Production"
    ASPNETCORE_URLS            = "http://0.0.0.0:8080"
    API__WILDCARDHOSTNAME      = var.wildcard_hostname
    DATABASE__PROVIDER         = "PostgreSQL"
    AUTHENTICATION__PROVIDER   = var.auth_provider
    AUTHENTICATION__CLIENTID   = var.auth_client_id
    AUTHENTICATION__ADMINROLES = var.auth_admin_roles
    AUTHENTICATION__DOMAIN     = var.auth_domain
    AUTHENTICATION__TENANTID   = var.auth_tenant_id
    AUTHENTICATION__INSTANCE   = var.auth_instance
    AUTHENTICATION__AUTHORITY  = var.auth_authority
    AUTHENTICATION__AUDIENCE   = var.auth_audience
  }
}

resource "azurerm_container_app" "broch" {
  name                         = "${var.name_prefix}-app"
  container_app_environment_id = azurerm_container_app_environment.broch.id
  resource_group_name          = azurerm_resource_group.broch.name
  revision_mode                = "Single"

  # Pinned to the environment's profile: Azure sets it anyway, and leaving it unset makes
  # every later plan try to clear it.
  workload_profile_name = "Consumption"

  lifecycle {
    # Broch refuses to start without each provider's required values, and only after the
    # database is migrated. Fail the plan instead. These mirror the server's startup checks;
    # an explicit auth_authority waives the domain/instance/tenant checks, as it does there.
    # Provider match is case-insensitive, as Broch binds it.
    precondition {
      condition     = trimspace(var.auth_client_id) != "" && trimspace(var.auth_client_secret) != ""
      error_message = "auth_client_id and auth_client_secret are required: Broch refuses to start with a provider but no client credentials."
    }
    precondition {
      condition     = lower(trimspace(var.auth_provider)) != "auth0" || trimspace(var.auth_audience) != ""
      error_message = "auth_audience is required when auth_provider is Auth0: set it to the Identifier of the Auth0 API your Broch application has user access to."
    }
    precondition {
      condition     = lower(trimspace(var.auth_provider)) != "oidc" || trimspace(var.auth_authority) != ""
      error_message = "auth_authority is required when auth_provider is Oidc: set it to your IdP's issuer URL."
    }
    precondition {
      condition = (!contains(["auth0", "okta"], lower(trimspace(var.auth_provider)))
      || trimspace(var.auth_authority) != "" || trimspace(var.auth_domain) != "")
      error_message = "auth_domain is required when auth_provider is Auth0 or Okta (e.g. your-tenant.auth0.com), unless you set auth_authority."
    }
    precondition {
      condition = (!contains(["azuread", "entraexternalid"], lower(trimspace(var.auth_provider)))
        || trimspace(var.auth_authority) != ""
      || (trimspace(var.auth_instance) != "" && trimspace(var.auth_tenant_id) != ""))
      error_message = "auth_instance and auth_tenant_id are required when auth_provider is AzureAd or EntraExternalId, unless you set auth_authority (AzureAd's instance is https://login.microsoftonline.com/, EntraExternalId's is https://<tenant>.ciamlogin.com/)."
    }
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.broch.id]
  }

  # Each Key Vault secret the container needs has to be re-declared here as
  # a Container Apps secret that points at the Key Vault entry by URI. The
  # `identity` field names the managed identity Container Apps uses to read.
  secret {
    name                = "auth-client-secret"
    key_vault_secret_id = azurerm_key_vault_secret.auth_client_secret.id
    identity            = azurerm_user_assigned_identity.broch.id
  }

  secret {
    name                = "master-key"
    key_vault_secret_id = azurerm_key_vault_secret.master_key.id
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
    transport        = "auto" # picks HTTP/2 + WebSocket support automatically

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 1
    max_replicas = 1 # Broch runs as one replica

    container {
      name   = "broch"
      image  = var.broch_image
      cpu    = var.container_cpu
      memory = var.container_memory

      dynamic "env" {
        for_each = local.broch_environment
        content {
          name  = env.key
          value = env.value
        }
      }
      # Secrets come from Key Vault (above). The identity provider's client secret is part of
      # the boot floor alongside the plain values in local.broch_environment.
      env {
        name        = "BROCH_MASTER_KEY"
        secret_name = "master-key"
      }
      env {
        name        = "ConnectionStrings__BrochConnection"
        secret_name = "postgres-connection-string"
      }
      env {
        name        = "AUTHENTICATION__CLIENTSECRET"
        secret_name = "auth-client-secret"
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
    azurerm_postgresql_flexible_server_database.broch,
  ]
}

# ─── Custom domains ──────────────────────────────────────────────────────────
#
# Container Apps' built-in managed certs handle the apex hostname fine but
# DON'T issue wildcards. So:
#   - The apex (broch.example.com) uses an Azure-managed cert
#   - The wildcard (*.broch.example.com) needs a cert you provision yourself
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
