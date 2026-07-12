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

The smallest footprint of the three Terraform modules. Tradeoff is the obvious one: single VM, no managed services, no failover.

## Prerequisites

- Terraform 1.6+ and the [DigitalOcean provider](https://registry.terraform.io/providers/digitalocean/digitalocean/latest/docs) (auto-installed by `terraform init`)
- A DigitalOcean account with an [API token](https://cloud.digitalocean.com/account/api/tokens)
- An SSH key [registered in DigitalOcean](https://cloud.digitalocean.com/account/security) — note the fingerprint
- A registered domain on a [Caddy-compatible DNS provider](https://github.com/caddy-dns) — DigitalOcean, Cloudflare (default), and GoDaddy are supported here (single-token DNS-01); DigitalOcean is the natural pick if your DNS zone is on DigitalOcean too. Route 53 needs an AWS key pair rather than a single token, so use the [aws-vm](../../cloudformation/aws-vm/) or [azure-vm](../../bicep/azure-vm/) appliance for a Route 53 domain
- A DNS provider API token with permission to edit the zone hosting your wildcard hostname
- An identity provider app registration (Azure Entra ID, Auth0, Okta, or any OIDC) — Broch has no built-in local login, so the IdP is configured at boot
- A Broch license — activated in-app after first sign-in (Admin → License)

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
# Add an A record: *.broch.example.com → <reserved IP>

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

This **recreates the Droplet** (cloud-init re-runs with the new image tag). Postgres data is preserved on the attached block storage volume, which is detached/reattached during the cycle. Two secrets are also persisted on that volume and restored on the new Droplet, so the recreated stack reconnects cleanly to the surviving state:

- the bundled-Postgres password (`/mnt/broch-data/postgres-password`) — so the new stack authenticates to the surviving database (Postgres ignores `POSTGRES_PASSWORD` once initialised);
- the `BROCH_MASTER_KEY` at-rest encryption root (`/mnt/broch-data/master-key`) — so ASP.NET Data Protection keys (auth/session cookies, OIDC correlation state) stored in Postgres and sealed with the old master key stay decryptable. Without this, a recreate would mint a fresh key and break auth/cookie/OIDC sign-in against the otherwise-intact database.

Expect ~3-4 min of downtime.

> **Upgrading a volume created by an older module version** (one that took `postgres_password` as a Terraform variable): before recreating the droplet, SSH in and write that password to the block volume so the new droplet can open the existing database — `printf '%s' '<your-postgres-password>' > /mnt/broch-data/postgres-password && chmod 0600 /mnt/broch-data/postgres-password`. Boot **fails loudly** (see `/var/log/cloud-init-output.log`) if an initialised database is found without this file, rather than minting a fresh password that cannot open it. The master key needs no action: older versions rolled it on every recreate anyway (users re-authenticate and the license re-activates once), and from this version on it persists across recreates.

For zero-downtime upgrades, move to the AWS or Azure Terraform modules — both use rolling deploys via their respective container schedulers.

## SSH access

```sh
$(terraform output -raw ssh_command)
# → ssh root@<reserved-ip>
```

The Droplet runs Docker Compose at `/opt/broch/`. `docker compose ps` shows the running services; `docker compose logs broch-server` tails server output.

> With the default `ssh_allowed_cidrs` (open to the internet), automated scanners constantly probe port 22 and can trip sshd's `MaxStartups` throttle — a legit `ssh` then fails with `kex_exchange_identification: Connection closed`. Retry, or set `ssh_allowed_cidrs` to your own CIDR to stop the noise.

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
| `s-1vcpu-1gb` default          | $6/mo baseline for evaluation; a 2 GB swapfile is added so the one-time Caddy build fits | More users, more tunnels, more idle headroom           |
| Single AZ                      | DO Droplets are AZ-bound; HA needs a load balancer + multi-droplet setup           | When you need cross-AZ failover                             |
| SSH closed by default          | Default `ssh_allowed_cidrs = []` adds no port-22 rule (use the DO console / a bastion) | Set `ssh_allowed_cidrs` to your bastion / VPN CIDRs for break-glass SSH    |
| No automated DB backups        | You configure your own via cron + DO Spaces or external storage                    | The minute the data matters                                 |
| Reserved IP without IPv6       | DO reserved IPs are v4-only                                                        | If you need v6, attach a floating v6 to the Droplet itself  |

## Secret exposure (read before production use)

This module is **not** yet at the azure-vm secret-handling baseline. Two classes of secret are handled differently:

- **Generated on-box, never in user_data (good):** the `BROCH_MASTER_KEY` at-rest encryption root and the **bundled Postgres password** are both generated on the droplet at first boot and written to `/opt/broch/.env` (mode `0600`). They never enter the droplet's cloud-init user_data. Both are also persisted to the block volume (`/mnt/broch-data/master-key`, `/mnt/broch-data/postgres-password`, mode `0600`) and restored on a droplet recreate, so the surviving database stays both reachable and decryptable (see [Upgrading the broch image](#upgrading-the-broch-image)).
- **Still rendered into user_data (residual exposure):** the **IdP client secret** (`auth_client_secret`) and the **DNS-01 API token** (`dns_api_token`) are interpolated into cloud-init user_data by `templatefile()`. DigitalOcean droplet user_data is retrievable from the link-local metadata endpoint (`http://169.254.169.254/metadata/v1/user_data`), which is reachable from **inside any container on the droplet** by default, and via the DO API to anyone holding the account token.

  **Risk:** a Broch RCE — or any compromised container on the box — can curl the metadata endpoint and lift your IdP client secret and DNS token without ever touching the host filesystem. These are *your own* secrets in *your own* DO account (not a vendor-owned sink), so the blast radius is your IdP app registration and DNS zone, but it is a real, avoidable exposure relative to the azure-vm module, which fetches these from Key Vault at boot so they never enter user_data.

  **Mitigations today:** scope the IdP client secret and the DNS token as tightly as your provider allows (e.g. a Cloudflare token limited to `Zone:Read + DNS:Edit` on the one zone); rotate them if you suspect a container compromise.

  A future revision may close this gap by fetching `auth_client_secret` and `dns_api_token` from a secret store at first boot (mirroring the azure-vm Key Vault boot-fetch) instead of baking them into user_data — DigitalOcean has no per-droplet managed-secret store, so the likely shape is a first-boot pull from DO Spaces or an external vault. Until then, use the scoping + rotation mitigations above.

## Teardown

```sh
terraform destroy
```

The block storage volume is destroyed along with the rest — if you want to keep the Postgres data, take a snapshot or export the database before running destroy.
