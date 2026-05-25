# Broch — DigitalOcean Terraform Outputs
# Copyright (c) 2026 Broch, LLC. All rights reserved.

output "droplet_ip" {
  description = "Reserved IP address of the Broch droplet"
  value       = digitalocean_reserved_ip.broch.ip_address
}

output "droplet_id" {
  description = "DigitalOcean Droplet ID"
  value       = digitalocean_droplet.broch.id
}

output "broch_url" {
  description = "URL to access Broch"
  value       = "https://${var.wildcard_hostname}"
}

output "ssh_command" {
  description = "SSH command to connect to the droplet"
  value       = "ssh root@${digitalocean_reserved_ip.broch.ip_address}"
}
