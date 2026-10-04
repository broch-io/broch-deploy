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
  description = "CIDRs allowed to reach SSH (port 22) on the droplet. Empty (default) creates NO SSH rule, so neither SSH nor the DigitalOcean Droplet Console can connect (the password-based Recovery Console still can). Set your bastion / VPN CIDRs to allow break-glass SSH."
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

  # Written single-quoted into the droplet's .env (see cloud-init.yaml), which can't carry these.
  validation {
    condition     = !can(regex("['\\n\\r]|\\\\$", var.central_server_url))
    error_message = "central_server_url can't contain a single quote or a line break, or end with a backslash: the droplet's .env quotes it."
  }
}

variable "wildcard_hostname" {
  description = "Wildcard hostname for tunnel subdomains (e.g., broch.company.com)"
  type        = string

  validation {
    condition     = trimspace(var.wildcard_hostname) != ""
    error_message = "wildcard_hostname is required: Broch refuses to start without it."
  }

  # Written single-quoted into the droplet's .env (see cloud-init.yaml), which can't carry these.
  validation {
    condition     = !can(regex("['\\n\\r]|\\\\$", var.wildcard_hostname))
    error_message = "wildcard_hostname can't contain a single quote or a line break, or end with a backslash: the droplet's .env quotes it."
  }
}

variable "image" {
  description = "Full Docker image name without tag (e.g. ghcr.io/broch-io/broch)"
  type        = string
  default     = "ghcr.io/broch-io/broch"
}

variable "image_tag" {
  description = "Docker image tag. Defaults to a concrete pinned version (NOT latest) so a droplet recreate never silently rolls the box across an EF-migration boundary; new releases of this template bump this default. Set a newer tag to upgrade deliberately, or \"latest\" to float (not recommended in production)."
  type        = string
  default     = "1.35.0"
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

  # Matched case-insensitively, as Broch binds it.
  validation {
    condition     = contains(["auth0", "azuread", "entraexternalid", "okta", "oidc"], lower(trimspace(var.auth_provider)))
    error_message = "auth_provider must be one of Auth0, AzureAd, EntraExternalId, Okta, Oidc."
  }

  # Written single-quoted into the droplet's .env (see cloud-init.yaml), which can't carry these.
  validation {
    condition     = !can(regex("['\\n\\r]|\\\\$", var.auth_provider))
    error_message = "auth_provider can't contain a single quote or a line break, or end with a backslash: the droplet's .env quotes it."
  }
}

variable "auth_client_id" {
  description = "OAuth2 client/application ID from IdP app registration"
  type        = string

  # Written single-quoted into the droplet's .env (see cloud-init.yaml), which can't carry these.
  validation {
    condition     = !can(regex("['\\n\\r]|\\\\$", var.auth_client_id))
    error_message = "auth_client_id can't contain a single quote or a line break, or end with a backslash: the droplet's .env quotes it."
  }
}

variable "auth_client_secret" {
  description = "OAuth2 client secret from IdP app registration"
  type        = string
  sensitive   = true

  # Written single-quoted into the droplet's .env (see cloud-init.yaml), which can't carry these.
  validation {
    condition     = !can(regex("['\\n\\r]|\\\\$", var.auth_client_secret))
    error_message = "auth_client_secret can't contain a single quote or a line break, or end with a backslash: the droplet's .env quotes it."
  }
}

variable "auth_tenant_id" {
  description = "IdP tenant ID (required for AzureAd and EntraExternalId unless auth_authority is set)"
  type        = string
  default     = ""

  # Written single-quoted into the droplet's .env (see cloud-init.yaml), which can't carry these.
  validation {
    condition     = !can(regex("['\\n\\r]|\\\\$", var.auth_tenant_id))
    error_message = "auth_tenant_id can't contain a single quote or a line break, or end with a backslash: the droplet's .env quotes it."
  }
}

variable "auth_instance" {
  description = "Login instance — defaults to https://login.microsoftonline.com/ for AzureAd; required for EntraExternalId (https://<tenant>.ciamlogin.com/) unless auth_authority is set. Leave blank for other providers."
  type        = string
  default     = ""

  # Written single-quoted into the droplet's .env (see cloud-init.yaml), which can't carry these.
  validation {
    condition     = !can(regex("['\\n\\r]|\\\\$", var.auth_instance))
    error_message = "auth_instance can't contain a single quote or a line break, or end with a backslash: the droplet's .env quotes it."
  }
}

variable "auth_domain" {
  description = "IdP domain (required for Auth0 and Okta unless auth_authority is set, e.g., contoso.auth0.com or contoso.okta.com)"
  type        = string
  default     = ""

  # Written single-quoted into the droplet's .env (see cloud-init.yaml), which can't carry these.
  validation {
    condition     = !can(regex("['\\n\\r]|\\\\$", var.auth_domain))
    error_message = "auth_domain can't contain a single quote or a line break, or end with a backslash: the droplet's .env quotes it."
  }
}

variable "auth_audience" {
  description = "Auth0 API audience — required for Auth0: the Identifier of the Auth0 API your Broch application has user access to. Leave blank for other providers."
  type        = string
  default     = ""

  # Written single-quoted into the droplet's .env (see cloud-init.yaml), which can't carry these.
  validation {
    condition     = !can(regex("['\\n\\r]|\\\\$", var.auth_audience))
    error_message = "auth_audience can't contain a single quote or a line break, or end with a backslash: the droplet's .env quotes it."
  }
}

variable "auth_authority" {
  description = "Issuer URL — required for the generic Oidc provider (serves /.well-known/openid-configuration). Leave blank for other providers."
  type        = string
  default     = ""

  # Written single-quoted into the droplet's .env (see cloud-init.yaml), which can't carry these.
  validation {
    condition     = !can(regex("['\\n\\r]|\\\\$", var.auth_authority))
    error_message = "auth_authority can't contain a single quote or a line break, or end with a backslash: the droplet's .env quotes it."
  }
}

# --- Admin ---

variable "admin_roles" {
  description = "Comma-separated IdP role/claim values that grant admin access. Your first admin signs in holding one of these."
  type        = string
  default     = "broch_admin"

  # Written single-quoted into the droplet's .env (see cloud-init.yaml), which can't carry these.
  validation {
    condition     = !can(regex("['\\n\\r]|\\\\$", var.admin_roles))
    error_message = "admin_roles can't contain a single quote or a line break, or end with a backslash: the droplet's .env quotes it."
  }
}

# --- Database ---

# NOTE: there is intentionally NO postgres_password variable. The bundled
# Postgres password is generated ON the droplet at first boot (see cloud-init.yaml) so the
# DB credential never enters droplet user_data. It lands in /opt/broch/.env at 0600 and is
# stable across reboots/cloud-init re-runs (the generator only fills the placeholder once),
# which Postgres requires since it ignores POSTGRES_PASSWORD after its data dir is initialised.
