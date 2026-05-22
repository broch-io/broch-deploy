# ─── Required ────────────────────────────────────────────────────────────────

variable "wildcard_hostname" {
  description = "Wildcard DNS hostname for Broch tunnels (e.g. tunnels.example.com). You must own the DNS zone — Azure does not manage your DNS unless you also use Azure DNS."
  type        = string
}

variable "broch_license" {
  description = "Broch license key. Stored in Key Vault; not committed to state or logs."
  type        = string
  sensitive   = true
}

variable "github_pat" {
  description = "GitHub PAT with read:packages, used by Container Apps to pull the broch image from GHCR while it's private. Stored in Key Vault."
  type        = string
  sensitive   = true
}

variable "github_username" {
  description = "GitHub username paired with github_pat for GHCR auth."
  type        = string
}

# ─── Optional ────────────────────────────────────────────────────────────────

variable "broch_image" {
  description = "Full image reference for the broch server. Pin to a specific version in production."
  type        = string
  default     = "ghcr.io/broch-io/broch:latest"
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
