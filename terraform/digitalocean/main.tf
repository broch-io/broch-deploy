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
  # somehow, and DigitalOcean has no per-droplet managed-secret store (the azure-vm Key Vault
  # boot-fetch equivalent). A future revision may fetch these from a secret store at first
  # boot; the residual exposure is documented in README.md ("Secret exposure").
  user_data = templatefile("${path.module}/cloud-init.yaml", {
    deployment_name    = var.deployment_name
    central_server_url = var.central_server_url
    wildcard_hostname  = var.wildcard_hostname
    auth_provider      = var.auth_provider
    auth_client_id     = var.auth_client_id
    auth_client_secret = var.auth_client_secret
    auth_tenant_id     = var.auth_tenant_id
    auth_instance      = var.auth_instance
    auth_domain        = var.auth_domain
    admin_roles        = var.admin_roles
    image              = var.image
    image_tag          = var.image_tag
    dns_env_var        = local.dns_env_var
    dns_api_token      = var.dns_api_token
    tls_fragment       = local.tls_fragment
    auth_audience      = var.auth_audience
    auth_authority     = var.auth_authority
  })
}

locals {
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

resource "digitalocean_reserved_ip" "broch" {
  region = var.region
}

# DigitalOcean serializes per-droplet actions: while one is in flight the API
# rejects the next with 422 "Droplet already has a pending event". Both the
# volume attachment and this reserved-IP assignment issue a droplet action, and
# Terraform creates them concurrently (each only references the droplet id), so
# whichever loses the race fails the apply. Order the IP assignment after the
# volume attachment so the two droplet actions never overlap.
resource "digitalocean_reserved_ip_assignment" "broch" {
  ip_address = digitalocean_reserved_ip.broch.ip_address
  droplet_id = digitalocean_droplet.broch.id

  depends_on = [digitalocean_volume_attachment.broch_data]
}

# --- Firewall ---

resource "digitalocean_firewall" "broch" {
  name        = var.deployment_name
  droplet_ids = [digitalocean_droplet.broch.id]

  # SSH is opt-in: no port-22 rule unless ssh_allowed_cidrs is set (default closed).
  # Manage the droplet via the DO console / a bastion otherwise.
  dynamic "inbound_rule" {
    for_each = length(var.ssh_allowed_cidrs) > 0 ? [1] : []
    content {
      protocol         = "tcp"
      port_range       = "22"
      source_addresses = var.ssh_allowed_cidrs
    }
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}
