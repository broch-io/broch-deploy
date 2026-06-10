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
    postgres_password  = var.postgres_password
    image              = var.image
    image_tag          = var.image_tag
    dns_provider       = var.dns_provider
    dns_api_token      = var.dns_api_token
    auth_audience      = var.auth_audience
    auth_authority     = var.auth_authority
  })
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

resource "digitalocean_reserved_ip_assignment" "broch" {
  ip_address = digitalocean_reserved_ip.broch.ip_address
  droplet_id = digitalocean_droplet.broch.id
}

# --- Firewall ---

resource "digitalocean_firewall" "broch" {
  name        = var.deployment_name
  droplet_ids = [digitalocean_droplet.broch.id]

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = var.ssh_allowed_cidrs
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
