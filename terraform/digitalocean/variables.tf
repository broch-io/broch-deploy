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
  description = "Wildcard hostname for tunnel subdomains (e.g., broch.company.com)"
  type        = string
}

variable "image" {
  description = "Full Docker image name without tag (e.g. ghcr.io/broch-io/broch)"
  type        = string
  default     = "ghcr.io/broch-io/broch"
}

variable "image_tag" {
  description = "Docker image tag. Defaults to a concrete pinned version (NOT latest) so a droplet recreate never silently rolls the box across an EF-migration boundary; new releases of this template bump this default. Set a newer tag to upgrade deliberately, or \"latest\" to float (not recommended in production)."
  type        = string
  default     = "1.30.0"
}


variable "dns_provider" {
  description = "DNS provider for Caddy DNS-01 (digitalocean, cloudflare, or godaddy). Selects the canonical tls fragment docker-compose/caddy-tls/<provider>.caddy embedded at deploy time. DigitalOcean is the natural choice when your domain's DNS is hosted on DigitalOcean too."
  type        = string
  default     = "cloudflare"
  validation {
    # Only single-token providers work here: the droplet receives ONE dns_api_token. digitalocean,
    # cloudflare, and godaddy each authenticate with a single token; route53 needs an AWS access-key
    # PAIR, so it is unsupported on DigitalOcean (use the aws-vm/azure-vm appliance for Route 53).
    # Each name must have a docker-compose/caddy-tls/<name>.caddy and a dns_env_var mapping in main.tf.
    condition     = contains(["digitalocean", "cloudflare", "godaddy"], var.dns_provider)
    error_message = "dns_provider must be one of: digitalocean, cloudflare, godaddy (single-token Caddy DNS-01 providers; route53 needs an AWS key pair — use the aws-vm/azure-vm appliance for Route 53)."
  }
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

# NOTE: there is intentionally NO postgres_password variable. The bundled
# Postgres password is generated ON the droplet at first boot (see cloud-init.yaml) so the
# DB credential never enters droplet user_data. It lands in /opt/broch/.env at 0600 and is
# stable across reboots/cloud-init re-runs (the generator only fills the placeholder once),
# which Postgres requires since it ignores POSTGRES_PASSWORD after its data dir is initialised.
