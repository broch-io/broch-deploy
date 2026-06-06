# DigitalOcean Terraform module

The simplest cloud Broch — a single DigitalOcean Droplet running Docker Compose, with the bundled Postgres on a separate block storage volume so droplet resizes don't lose data. Caddy handles automatic wildcard TLS via ACME DNS-01.

## What this provisions

```
                                    ┌─────────────────────────────┐
internet  ─── HTTPS:443  ─────▶     │ DigitalOcean Droplet         │
                                    │   Ubuntu 24.04 + Docker      │
                                    │  ┌───────────────────────┐   │
                                    │  │ caddy                 │   │
                                    │  │   wildcard TLS DNS-01 │   │
                                    │  └──────────┬────────────┘   │
                                    │             │ http:8080      │
                                    │  ┌──────────▼────────────┐   │
                                    │  │ broch                 │   │
                                    │  └──────────┬────────────┘   │
                                    │             │ tcp:5432       │
                                    │  ┌──────────▼────────────┐   │
                                    │  │ postgres:16-alpine    │   │
                                    │  └───────────────────────┘   │
                                    │             │                │
                                    │  ┌──────────▼────────────┐   │
                                    │  │ Block storage volume   │   │
                                    │  │   /mnt/broch-data      │   │
                                    │  └───────────────────────┘   │
                                    └──────────────┬───────────────┘
                                                   │
                                    Reserved IP (stable DNS target)
```

The Droplet is firewalled: only SSH (22) and HTTPS (443) inbound from the public internet. Caddy redirects HTTP→HTTPS internally.

## What it costs

Rough monthly numbers (as of 2026):

| Resource                              | ~Monthly cost (USD) |
| ------------------------------------- | ------------------- |
| Droplet `s-1vcpu-1gb`                 | $6                  |
| Reserved IP (attached, no charge)     | $0                  |
| Block storage 10 GB                   | $1                  |
| Bandwidth (1 TB included with Droplet)| $0                  |
| **Total baseline**                    | **~$7/month**       |

The cheapest cloud option of the three Terraform modules — by a wide margin. Tradeoff is the obvious one: single VM, no managed services, no failover.

## Prerequisites

- Terraform 1.6+ and the [DigitalOcean provider](https://registry.terraform.io/providers/digitalocean/digitalocean/latest/docs) (auto-installed by `terraform init`)
- A DigitalOcean account with an [API token](https://cloud.digitalocean.com/account/api/tokens)
- An SSH key [registered in DigitalOcean](https://cloud.digitalocean.com/account/security) — note the fingerprint
- A registered domain on a [Caddy-compatible DNS provider](https://github.com/caddy-dns) — Cloudflare, GoDaddy, and Route 53 are compiled in by default
- A DNS provider API token with permission to edit the zone hosting your wildcard hostname
- An identity provider app registration (Azure Entra ID, Auth0, Okta, or any OIDC) — Broch has no built-in local login, so the IdP is configured at boot
- Optional: a Broch license key — activate in-app after first sign-in, or set `license_key` to pre-seed it
- A GitHub PAT with `read:packages` (while `ghcr.io/broch-io/broch` is private)

## Setup

```sh
# 1. Copy + fill the tfvars template
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

# 2. Apply (3-4 min — Droplet provision + cloud-init bootstrap + image pull)
terraform init
terraform apply

# 3. After apply, point DNS at the reserved IP
echo "Reserved IP: $(terraform output -raw droplet_ip)"
# Add an A record: *.tunnels.example.com → <reserved IP>

# 4. Wait for Caddy to issue certs (~30-60s after DNS propagates), then verify
curl -fsS "$(terraform output -raw broch_url)/healthz"
```

## State storage

State defaults to local (`terraform.tfstate` next to this file). For team use, add a `backend` block to `main.tf` targeting DigitalOcean Spaces or any S3-compatible store:

```hcl
terraform {
  backend "s3" {
    bucket                      = "your-bucket"
    key                         = "broch/terraform.tfstate"
    endpoint                    = "nyc3.digitaloceanspaces.com"
    region                      = "us-east-1"
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    force_path_style            = true
  }
}
```

Pass credentials at init time: `terraform init -backend-config="access_key=..." -backend-config="secret_key=..."`.

## Upgrading the broch image

```sh
$EDITOR terraform.tfvars      # bump image_tag
terraform apply
```

This **recreates the Droplet** (cloud-init re-runs with the new image tag). Postgres data is preserved on the attached block storage volume, which is detached/reattached during the cycle. Expect ~3-4 min of downtime.

For zero-downtime upgrades, move to the AWS or Azure Terraform modules — both use rolling deploys via their respective container schedulers.

## SSH access

```sh
$(terraform output -raw ssh_command)
# → ssh root@<reserved-ip>
```

The Droplet runs Docker Compose at `/opt/broch/`. `docker compose ps` shows the running services; `docker compose logs broch` tails server output.

## Backup

```sh
# Snapshot the Postgres DB to your local machine
ssh root@$(terraform output -raw droplet_ip) \
  "cd /opt/broch && docker compose exec -T postgres pg_dump -U broch brochdb" \
  > broch-$(date +%Y%m%d).sql

# Restore
cat broch-20260525.sql | ssh root@$(terraform output -raw droplet_ip) \
  "cd /opt/broch && docker compose exec -T postgres psql -U broch brochdb"
```

Block storage volume snapshots via the DigitalOcean console are also fine and cover everything.

## Tradeoffs / what's deliberately not here

| Decision                       | Why                                                                                | When to change                                              |
| ------------------------------ | ---------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| Single Droplet                 | Cheapest cloud Broch                                                               | When you need HA or scale beyond a single VM                |
| Embedded Postgres              | One less service to operate                                                        | When you need encryption-at-rest, PITR, or multi-replica    |
| `s-1vcpu-1gb` default          | $6/mo baseline for evaluation; bump for real load                                  | More users, more tunnels, more idle headroom                |
| Single AZ                      | DO Droplets are AZ-bound; HA needs a load balancer + multi-droplet setup           | When you need cross-AZ failover                             |
| Firewall: SSH from 0.0.0.0/0   | Convenient for setup                                                               | Lock to your bastion / VPN CIDR before going to real prod   |
| No automated DB backups        | You configure your own via cron + DO Spaces or external storage                    | The minute the data matters                                 |
| Reserved IP without IPv6       | DO reserved IPs are v4-only                                                        | If you need v6, attach a floating v6 to the Droplet itself  |

## Teardown

```sh
terraform destroy
```

The block storage volume is destroyed along with the rest — if you want to keep the Postgres data, take a snapshot or export the database before running destroy.
