data "azurerm_client_config" "current" {}

locals {
  # Azure resource names have tight rules — most need to be globally unique
  # for certain types and locally unique for others. Suffix with a random
  # hex string so re-applies after `destroy` don't collide with soft-deleted
  # key-vault names.
  suffix = random_id.suffix.hex
}

resource "random_id" "suffix" {
  byte_length = 3
}

# ─── Resource group ──────────────────────────────────────────────────────────

resource "azurerm_resource_group" "broch" {
  name     = "${var.name_prefix}-rg"
  location = var.location

  tags = {
    project    = "broch"
    managed_by = "terraform"
    module     = "broch-deploy/azure-container-apps"
  }
}

# ─── Log Analytics workspace (required by Container Apps environment) ────────

resource "azurerm_log_analytics_workspace" "broch" {
  name                = "${var.name_prefix}-logs"
  resource_group_name = azurerm_resource_group.broch.name
  location            = azurerm_resource_group.broch.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

# ─── Key Vault for secrets ───────────────────────────────────────────────────

resource "azurerm_key_vault" "broch" {
  # Vault names must be globally unique and 3-24 chars.
  name                       = substr("${var.name_prefix}-kv-${local.suffix}", 0, 24)
  resource_group_name        = azurerm_resource_group.broch.name
  location                   = azurerm_resource_group.broch.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 7
  purge_protection_enabled   = false # set true in production

  rbac_authorization_enabled = true # use RBAC instead of access policies
}

# Caller (whoever runs `terraform apply`) needs to be able to write the
# initial secret values. The Container App's managed identity then gets a
# read-only role binding below.
resource "azurerm_role_assignment" "kv_caller_admin" {
  scope                = azurerm_key_vault.broch.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_key_vault_secret" "broch_license" {
  name         = "broch-license"
  value        = var.broch_license
  key_vault_id = azurerm_key_vault.broch.id

  depends_on = [azurerm_role_assignment.kv_caller_admin]
}

resource "azurerm_key_vault_secret" "github_pat" {
  name         = "github-pat"
  value        = var.github_pat
  key_vault_id = azurerm_key_vault.broch.id

  depends_on = [azurerm_role_assignment.kv_caller_admin]
}
