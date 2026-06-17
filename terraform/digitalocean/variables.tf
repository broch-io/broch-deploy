# Broch — DigitalOcean Terraform Variables
# Copyright (c) 2026 Broch, LLC. All rights reserved.

# --- DigitalOcean ---

variable "do_token" {
  description = "DigitalOcean API token"
  type        = string
  sensitive   = true
}

variable "region" {
  description = "DigitalOcean region (e.g., nyc3, sfo3, ams3)"
  type        = string
  default     = "nyc3"
}

variable "droplet_size" {
  description = "Droplet size slug (s-1vcpu-1gb for Basic, s-2vcpu-2gb for Standard)"
  type        = string
  default     = "s-1vcpu-1gb"
}

variable "ssh_key_fingerprint" {
  description = "Fingerprint of the SSH key registered in DigitalOcean"
  type        = string
}

variable "ssh_allowed_cidrs" {
  description = "CIDRs allowed to reach SSH (port 22) on the droplet. Empty (default) creates NO SSH rule — manage the droplet via the DigitalOcean console / a bastion. Set your bastion / VPN CIDRs to allow break-glass SSH."
  type        = list(string)
  default     = []
}

variable "deployment_name" {
  description = "Unique name for this deployment (used in resource names, e.g., broch-okta, broch-entra)"
  type        = string
  default     = "broch-server"
}

variable "volume_size" {
  description = "Block storage volume size in GB for PostgreSQL data"
  type        = number
  default     = 10
}

# --- Broch ---

variable "central_server_url" {
  description = "URL of the Broch Central Server API for license validation"
  type        = string
  default     = "https://api.broch.io"
}

variable "wildcard_hostname" {
  description = "Wildcard hostname for tunnel subdomains (e.g., tunnels.company.com)"
  type        = string
}

variable "image" {
  description = "Full Docker image name without tag (e.g. ghcr.io/broch-io/broch)"
  type        = string
  default     = "ghcr.io/broch-io/broch"
}

variable "image_tag" {
  description = "Docker image tag"
  type        = string
  default     = "latest"
}


variable "dns_provider" {
  description = "DNS provider name matching the compiled Caddy plugin (cloudflare, godaddy, route53)"
  type        = string
  default     = "cloudflare"
}

variable "dns_api_token" {
  description = "DNS provider API token for Caddy DNS-01 ACME challenges (wildcard TLS)"
  type        = string
  sensitive   = true
}

# --- Authentication ---

variable "auth_provider" {
  description = "Identity provider type (AzureAd, EntraExternalId, Auth0, Okta, Oidc)"
  type        = string
  default     = "AzureAd"
}

variable "auth_client_id" {
  description = "OAuth2 client/application ID from IdP app registration"
  type        = string
}

variable "auth_client_secret" {
  description = "OAuth2 client secret from IdP app registration"
  type        = string
  sensitive   = true
}

variable "auth_tenant_id" {
  description = "IdP tenant ID (required for AzureAd and EntraExternalId)"
  type        = string
  default     = ""
}

variable "auth_instance" {
  description = "IdP instance URL (e.g., https://login.microsoftonline.com/)"
  type        = string
  default     = "https://login.microsoftonline.com/"
}

variable "auth_domain" {
  description = "IdP domain (required for Auth0 and Okta, e.g., contoso.auth0.com or contoso.okta.com)"
  type        = string
  default     = ""
}

variable "auth_audience" {
  description = "OAuth2 audience (required for Okta)"
  type        = string
  default     = ""
}

variable "auth_authority" {
  description = "Issuer URL — required for the generic Oidc provider (serves /.well-known/openid-configuration). Leave blank for other providers."
  type        = string
  default     = ""
}

# --- Admin ---

variable "admin_roles" {
  description = "Comma-separated IdP role/claim values that grant admin access"
  type        = string
  default     = ""
}

# --- Database ---

variable "postgres_password" {
  description = "Password for the PostgreSQL database"
  type        = string
  sensitive   = true
}
