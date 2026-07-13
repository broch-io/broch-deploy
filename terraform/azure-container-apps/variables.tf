# ─── Required ────────────────────────────────────────────────────────────────

variable "wildcard_hostname" {
  description = "Wildcard DNS hostname for Broch tunnels (e.g. broch.example.com). You must own the DNS zone — Azure does not manage your DNS unless you also use Azure DNS."
  type        = string
}

# ─── Identity provider (required at boot) ────────────────────────────────────
# Broch authenticates every user through your IdP — there is no built-in local
# login, so the IdP is part of the boot floor. The server starts without these,
# but no one can sign in (or finish first-run setup) until they're set. Set the
# provider-specific values your IdP needs; leave the rest blank.
# Guides: https://broch.io/docs/identity-providers/

variable "auth_provider" {
  description = "Identity provider type: Auth0 | AzureAd | EntraExternalId | Okta | Oidc."
  type        = string
}

variable "auth_client_id" {
  description = "OAuth client ID from your IdP."
  type        = string
}

variable "auth_client_secret" {
  description = "OAuth client secret from your IdP. Stored in Key Vault; not committed to state or logs."
  type        = string
  sensitive   = true
}

variable "auth_admin_roles" {
  description = "Comma-separated role/group names that grant admin access. Your first admin signs in holding one of these."
  type        = string
  default     = "broch_admin"
}

variable "auth_domain" {
  description = "IdP domain — required for Auth0 and Okta (e.g. your-tenant.auth0.com). Leave blank for other providers."
  type        = string
  default     = ""
}

variable "auth_tenant_id" {
  description = "Tenant ID — required for AzureAd and EntraExternalId. Leave blank for other providers."
  type        = string
  default     = ""
}

variable "auth_instance" {
  description = "Login instance for AzureAd/EntraExternalId (e.g. https://login.microsoftonline.com/). Leave blank for other providers."
  type        = string
  default     = ""
}

variable "auth_authority" {
  description = "Issuer URL — required for the generic Oidc provider (serves /.well-known/openid-configuration). Leave blank for other providers."
  type        = string
  default     = ""
}

variable "auth_audience" {
  description = "OAuth audience identifier. Optional; falls back to the client ID."
  type        = string
  default     = ""
}

# ─── Optional ────────────────────────────────────────────────────────────────

variable "broch_image" {
  description = "Full image reference for the broch server. Defaults to a concrete pinned version (NOT :latest) so a revision restart never silently rolls the app across an EF-migration boundary; new releases of this template bump this default. Set a newer tag to upgrade deliberately, or :latest to float (not recommended in production)."
  type        = string
  default     = "ghcr.io/broch-io/broch:1.30.0"
}

variable "location" {
  description = "Azure region. Container Apps + Postgres Flexible Server must be in the same region."
  type        = string
  default     = "eastus"
}

variable "name_prefix" {
  description = "Prefix applied to all named Azure resources. Use this to deploy multiple broch stacks in one subscription."
  type        = string
  default     = "broch"
}

variable "container_cpu" {
  description = "Container Apps CPU allocation in vCPU. Valid values: 0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2."
  type        = number
  default     = 0.5
}

variable "container_memory" {
  description = "Container Apps memory allocation in GiB. Must be 2x the CPU value (0.5 vCPU → 1.0Gi memory)."
  type        = string
  default     = "1Gi"
}

variable "postgres_sku" {
  description = "Postgres Flexible Server SKU. B_Standard_B1ms is the smallest burstable tier."
  type        = string
  default     = "B_Standard_B1ms"
}

variable "postgres_storage_mb" {
  description = "Postgres Flexible Server storage in MB. Minimum is 32768 (32 GB)."
  type        = number
  default     = 32768
}

variable "postgres_db_name" {
  description = "Database name inside the Postgres server."
  type        = string
  default     = "brochdb"
}

variable "postgres_user" {
  description = "Postgres admin username."
  type        = string
  default     = "broch"
}
