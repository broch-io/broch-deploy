# DigitalOcean Droplet running Broch via Docker Compose with embedded
# PostgreSQL on attached block storage. Caddy handles wildcard TLS via
# ACME DNS-01.
#
# State defaults to local (terraform.tfstate next to this file). For
# team use, add a `backend "s3"` block targeting DigitalOcean Spaces or
# any S3-compatible store, and pass credentials via `-backend-config`.

terraform {
  required_version = ">= 1.6"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
  }
}

provider "digitalocean" {
  token = var.do_token
}

# --- Block Storage for PostgreSQL data persistence ---

resource "digitalocean_volume" "broch_data" {
  region                  = var.region
  name                    = "${var.deployment_name}-data"
  size                    = var.volume_size
  initial_filesystem_type = "ext4"
  description             = "Persistent storage for ${var.deployment_name} PostgreSQL data"

  lifecycle {
    # Guard against data loss: a destroy, or a change that replaces the volume, stops at plan
    # instead of deleting the database. Before an intentional destroy, delete this line (or set
    # it to false) and run the command again.
    prevent_destroy = true
  }
}

# --- Droplet ---

resource "digitalocean_droplet" "broch" {
  image    = "ubuntu-24-04-x64"
  name     = var.deployment_name
  region   = var.region
  size     = var.droplet_size
  ssh_keys = [var.ssh_key_fingerprint]

  # NOTE: postgres_password is NOT passed in — it is generated ON the droplet
  # at first boot (like BROCH_MASTER_KEY) so the bundled DB credential never enters droplet
  # user_data (which is readable from the link-local metadata endpoint by any container on
  # the box, and via the DO API to the account-token holder). See cloud-init.yaml's runcmd.
  #
  # The IdP client secret (auth_client_secret) and the DNS-01 token (dns_api_token) DO still
  # ride in user_data: they are values you hold off-box and the droplet must receive them
  # somehow, and DigitalOcean has no per-droplet managed-secret store (the azure-vm Key Vault /
  # aws-vm Secrets Manager boot-fetch equivalent). cloud-init installs a DOCKER-USER firewall rule
  # that DROPS bridge traffic to the link-local metadata endpoint (169.254.169.254), so a compromised
  # container in the (bridge-networked) stack can no longer read user_data via metadata -- closing the
  # in-container path. (DOCKER-USER only governs bridge-forwarded traffic; a --network=host container
  # would bypass it, but the shipped stack uses none.)
  # The DO-API read path (any holder of the account token) is the remaining residual, documented in
  # README.md ("Secret exposure") with scoping + rotation guidance. A future revision may close it
  # fully by fetching these from a secret store at first boot.
  user_data = local.user_data

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
      || (trimspace(local.auth_instance) != "" && trimspace(var.auth_tenant_id) != ""))
      error_message = "auth_tenant_id is required when auth_provider is AzureAd or EntraExternalId, and EntraExternalId also needs auth_instance (https://<tenant>.ciamlogin.com/), unless you set auth_authority."
    }
  }
}

locals {
  # AzureAd's login instance is the same for every tenant, so it defaults; EntraExternalId's is
  # tenant-specific (ciamlogin.com), so it has none and the precondition requires it.
  auth_instance = (trimspace(var.auth_instance) != "" ? var.auth_instance
  : lower(trimspace(var.auth_provider)) == "azuread" ? "https://login.microsoftonline.com/" : "")

  # The droplet's cloud-init, which writes Broch's .env. A local so the configuration contract check
  # (scripts/config-contract.py) can render exactly what this module sends and ask Broch whether it
  # would start with it.
  user_data = templatefile("${path.module}/cloud-init.yaml", {
    deployment_name    = var.deployment_name
    central_server_url = var.central_server_url
    wildcard_hostname  = var.wildcard_hostname
    auth_provider      = var.auth_provider
    auth_client_id     = var.auth_client_id
    auth_client_secret = var.auth_client_secret
    auth_tenant_id     = var.auth_tenant_id
    auth_instance      = local.auth_instance
    auth_domain        = var.auth_domain
    admin_roles        = var.admin_roles
    image              = var.image
    image_tag          = var.image_tag
    dns_env_var        = local.dns_env_var
    # Into the compose file's environment list, which compose interpolates: $$ is a literal $.
    dns_api_token  = replace(var.dns_api_token, "$", "$$")
    tls_fragment   = local.tls_fragment
    auth_audience  = var.auth_audience
    auth_authority = var.auth_authority
  })

  # The Caddy DNS-01 `tls` block comes from the CANONICAL single source
  # docker-compose/caddy-tls/<provider>.caddy (propagation tuning baked in) -- the SAME fragments
  # bicep/azure-vm loadTextContent()s and cloudformation/aws-vm base64-embeds. One definition; every
  # target consumes it. Written to /opt/broch/tls.caddy and imported by the Caddyfile (same as the
  # compose variants). Only single-token providers work on DigitalOcean -- route53 needs an AWS key
  # PAIR, not one token -- so var.dns_provider is validated to digitalocean | cloudflare | godaddy.
  tls_fragment = file("${path.module}/../../docker-compose/caddy-tls/${var.dns_provider}.caddy")

  # The env var each provider's fragment reads its token from (see the {env.*} ref in the fragment).
  dns_env_var = lookup({
    digitalocean = "DO_AUTH_TOKEN"
    cloudflare   = "CLOUDFLARE_API_TOKEN"
    godaddy      = "GODADDY_API_TOKEN"
  }, var.dns_provider, "CLOUDFLARE_API_TOKEN")
}

# --- Attach block storage to droplet ---

resource "digitalocean_volume_attachment" "broch_data" {
  droplet_id = digitalocean_droplet.broch.id
  volume_id  = digitalocean_volume.broch_data.id
}

# --- Reserved IP for stable DNS ---

# The IP is created and assigned in one resource (droplet_id set), not as an
# unassigned reserved IP plus a separate digitalocean_reserved_ip_assignment.
# Creating a bare reserved IP reads it back immediately, and DigitalOcean's API
# can still answer 404 for a reserved IP it has just created; the provider then
# drops it from state ("Provider produced inconsistent result after apply ...
# Root object was present, but now absent"), so the apply fails and the IP is
# left behind, billing while unassigned, where `terraform destroy` cannot see
# it. With droplet_id set, the provider records the IP in state before it
# assigns and waits on the assignment, so a failure there still leaves the IP
# in state for the next apply or destroy, and its final read-back only runs
# once the assignment has completed, when a 404 is far less likely.
#
# DigitalOcean also serializes per-droplet actions: while one is in flight the
# API rejects the next with 422 "Droplet already has a pending event". Both the
# volume attachment and this assignment issue a droplet action, so order the IP
# after the volume attachment and the two never overlap.
resource "digitalocean_reserved_ip" "broch" {
  region     = var.region
  droplet_id = digitalocean_droplet.broch.id

  depends_on = [digitalocean_volume_attachment.broch_data]
}

# --- Firewall ---

resource "digitalocean_firewall" "broch" {
  name        = var.deployment_name
  droplet_ids = [digitalocean_droplet.broch.id]

  # SSH is opt-in: no port-22 rule unless ssh_allowed_cidrs is set (default closed).
  # The Droplet Console needs that rule too; only the Recovery Console works without it.
  dynamic "inbound_rule" {
    for_each = length(var.ssh_allowed_cidrs) > 0 ? [1] : []
    content {
      protocol         = "tcp"
      port_range       = "22"
      source_addresses = var.ssh_allowed_cidrs
    }
  }

  # Public 443 is the service; SSH stays closed unless ssh_allowed_cidrs is set.
  # trivy:ignore:DIG-0001
  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # Outbound is open: ACME, the DNS API, the registry, the license server and the IdP have no fixed addresses.
  # trivy:ignore:DIG-0003
  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  # Outbound is open (see the TCP rule).
  # trivy:ignore:DIG-0003
  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  # Outbound is open: ACME, the DNS API, the registry, the license server and the IdP have no fixed addresses.
  # trivy:ignore:DIG-0003
  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}
