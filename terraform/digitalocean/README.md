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

The Droplet is firewalled: only HTTPS (443) inbound from the public internet. SSH (22) is closed unless you set `ssh_allowed_cidrs` (empty by default). Port 80 is closed too, so there is no HTTP→HTTPS redirect: use `https://` URLs (an `http://` request times out).

The smallest footprint of the three Terraform modules. Tradeoff is the obvious one: single VM, no managed services, no failover.

## Prerequisites

- Terraform 1.6+ and the [DigitalOcean provider](https://registry.terraform.io/providers/digitalocean/digitalocean/latest/docs) (auto-installed by `terraform init`)
- A DigitalOcean account with an [API token](https://cloud.digitalocean.com/account/api/tokens)
- An SSH key [registered in DigitalOcean](https://cloud.digitalocean.com/account/security) — note the fingerprint (`ssh_key_fingerprint` is required even though SSH starts closed)
- A registered domain on a [Caddy-compatible DNS provider](https://github.com/caddy-dns) — DigitalOcean, Cloudflare (default), and GoDaddy are supported here (single-token DNS-01); DigitalOcean is the natural pick if your DNS zone is on DigitalOcean too. Route 53 needs an AWS key pair rather than a single token, so use the [aws-vm](../../cloudformation/aws-vm/) or [azure-vm](../../bicep/azure-vm/) appliance for a Route 53 domain
- A DNS provider API token with permission to edit the zone hosting your wildcard hostname
- An identity provider app registration (Azure Entra ID, Auth0, Okta, or any OIDC) — Broch has no built-in local login, so the IdP is configured at boot. See the [identity-provider guides](https://broch.io/docs/identity-providers/). Auth0 also needs an **API** (its Identifier is `auth_audience`), with the Broch application authorized for **User Access** on the API's **Application Access** tab — an API that requires that grant rejects every sign-in without it
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
# Add two A records (a wildcard doesn't cover the bare name):
#   broch.example.com    → <reserved IP>
#   *.broch.example.com  → <reserved IP>

# 4. Wait for Caddy to issue certs (~30-60s after DNS propagates), then verify
curl -fsS "$(terraform output -raw broch_url)/healthz"
```

`terraform plan` refuses sign-in settings Broch would refuse at startup: an unknown `auth_provider`, a missing client ID or secret, or a value your provider needs (Auth0 and Okta need `auth_domain`, AzureAd and EntraExternalId need `auth_instance` and `auth_tenant_id`, each unless you set `auth_authority` instead; Oidc needs `auth_authority`; Auth0 also needs `auth_audience`). On this module `auth_instance` defaults to `https://login.microsoftonline.com/` for AzureAd only; EntraExternalId needs its tenant's `https://<tenant>.ciamlogin.com/`.

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

> **Upgrading from a module version that used a separate reserved-IP assignment resource:** the first apply on this version moves the reserved IP's assignment onto the reserved IP itself. The IP address stays the same, so DNS needs no change, but it is unassigned and then reassigned to the new Droplet, so the HTTPS endpoint is unreachable for that part of the apply (within the downtime above).

> **Upgrading a volume created by an older module version** (one that took `postgres_password` as a Terraform variable): before recreating the droplet, SSH in and write that password to the block volume so the new droplet can open the existing database — `printf '%s' '<your-postgres-password>' > /mnt/broch-data/postgres-password && chmod 0600 /mnt/broch-data/postgres-password`. If SSH is closed, open it by hand first: add a port-22 rule for your IP to the Droplet's firewall in the control panel (Networking → Firewalls) or with `doctl compute firewall add-rules <firewall-id> --inbound-rules "protocol:tcp,ports:22,address:<your-ip>/32"` (`doctl compute firewall list --format ID,Name` shows the ID). Don't open it with `terraform apply` from the newer checkout: that also changes the Droplet's user_data, so it recreates the Droplet before you get in, and `-target` on the firewall doesn't avoid that (it pulls in the Droplet the firewall attaches to). The next full apply sets the firewall back to `ssh_allowed_cidrs`. Boot **fails loudly** (see `/var/log/cloud-init-output.log`) if an initialised database is found without this file, rather than minting a fresh password that cannot open it. The master key needs no action: older versions rolled it on every recreate anyway (users re-authenticate and the license re-activates once), and from this version on it persists across recreates.

## SSH access

SSH is closed by default. To open it, set `ssh_allowed_cidrs = ["<your-ip>/32"]` in `terraform.tfvars` and run `terraform apply`; on the checkout you deployed from, only the firewall changes.

```sh
$(terraform output -raw ssh_command)
# → ssh root@<reserved-ip>
```

The Droplet runs Docker Compose at `/opt/broch/`. `docker compose ps` shows the running services; `docker compose logs broch-server` tails server output.

> If `ssh_allowed_cidrs` opens port 22 to a wide range (such as `0.0.0.0/0`), automated scanners constantly probe it and can trip sshd's `MaxStartups` throttle — a legit `ssh` then fails with `kex_exchange_identification: Connection closed`. Retry, or narrow `ssh_allowed_cidrs` to your own CIDR to stop the noise.

## Backup

These commands use SSH, so open it first (see [SSH access](#ssh-access)).

```sh
# Snapshot the Postgres DB to your local machine
ssh root@$(terraform output -raw droplet_ip) \
  "cd /opt/broch && docker compose exec -T postgres pg_dump -U broch brochdb" \
  > broch-$(date +%Y%m%d).sql

# Restore: stop broch, recreate the database, load the dump, then start broch only if the load succeeded
BACKUP=broch-YYYYMMDD.sql   # the dump file you are restoring
test -s "$BACKUP" && ssh root@$(terraform output -raw droplet_ip) \
  "cd /opt/broch && docker compose stop broch-server && docker compose exec -T postgres dropdb -U broch brochdb && docker compose exec -T postgres createdb -U broch -O broch brochdb"
ssh root@$(terraform output -raw droplet_ip) \
  "cd /opt/broch && docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U broch -d brochdb" < "$BACKUP" \
  && ssh root@$(terraform output -raw droplet_ip) "cd /opt/broch && docker compose up -d"
```

Block storage volume snapshots via the DigitalOcean console are also fine and cover everything.

## Tradeoffs / what's deliberately not here

| Decision                       | Why                                                                                | When to change                                              |
| ------------------------------ | ---------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| Single Droplet                 | Cheapest cloud Broch; Broch runs as one instance and doesn't cluster               | Scale up with `droplet_size`                                |
| Embedded Postgres              | One less service to operate                                                        | When you need PITR                                          |
| `s-1vcpu-1gb` default          | $6/mo baseline for evaluation; a 2 GB swapfile is added so the one-time Caddy build fits | More users, more tunnels, more idle headroom           |
| Single AZ                      | Droplets are AZ-bound and Broch runs as one instance, so there is no failover      | Keep it; recover from a volume snapshot ([Backup](#backup)) |
| SSH closed by default          | Default `ssh_allowed_cidrs = []` adds no port-22 rule, so SSH and the Droplet Console can't connect (the Recovery Console can) | Set `ssh_allowed_cidrs` to your bastion / VPN CIDRs for break-glass SSH    |
| No automated DB backups        | You configure your own via cron + DO Spaces or external storage                    | The minute the data matters                                 |
| Reserved IP without IPv6       | DO reserved IPs are v4-only                                                        | If you need v6, attach a floating v6 to the Droplet itself  |

## Secret exposure (read before production use)

This module is **not** yet at the azure-vm secret-handling baseline. Two classes of secret are handled differently:

- **Generated on-box, never in user_data (good):** the `BROCH_MASTER_KEY` at-rest encryption root and the **bundled Postgres password** are both generated on the droplet at first boot and written to `/opt/broch/.env` (mode `0600`). They never enter the droplet's cloud-init user_data. Both are also persisted to the block volume (`/mnt/broch-data/master-key`, `/mnt/broch-data/postgres-password`, mode `0600`) and restored on a droplet recreate, so the surviving database stays both reachable and decryptable (see [Upgrading the broch image](#upgrading-the-broch-image)).
- **Still rendered into user_data (residual exposure, in-container path now closed):** the **IdP client secret** (`auth_client_secret`) and the **DNS-01 API token** (`dns_api_token`) are interpolated into cloud-init user_data by `templatefile()`. DigitalOcean droplet user_data is retrievable from the link-local metadata endpoint (`http://169.254.169.254/metadata/v1/user_data`) and via the DO API to anyone holding the account token.

  **In-container read path — closed for the shipped stack.** cloud-init installs a firewall rule (`DOCKER-USER` chain) that **drops all bridge traffic to `169.254.169.254`**, installed *before* dockerd starts containers and re-applied on any dockerd restart by `broch-metadata-firewall.service`. The broch/caddy/postgres containers all run on the default bridge network, so a Broch RCE — or any compromised container in the stack — can **no longer** curl the metadata endpoint to lift these secrets. (`DOCKER-USER` only governs bridge-forwarded traffic, so a container a customer later runs with `--network=host` would bypass it; the shipped stack uses none.) This is the zero-operator-cost equivalent of the azure-vm (Key Vault) / aws-vm (Secrets Manager) boot-fetch, which DigitalOcean cannot match directly because it has no per-droplet managed-secret store.

  **DO-API read path — remaining residual.** Anyone holding a **DigitalOcean API token** for the account can still read the droplet's user_data through the DO API (the firewall rule only governs on-box container traffic, not the control-plane API). These are *your own* secrets in *your own* DO account (not a vendor-owned sink), so the blast radius is your IdP app registration and DNS zone.

  **Mitigations for the residual:** scope the IdP client secret and the DNS token as tightly as your provider allows (e.g. a Cloudflare token limited to `Zone:Read + DNS:Edit` on the one zone); guard DO API tokens and rotate the IdP/DNS secrets if you suspect either an account-token or a container compromise.

  A future revision may close the DO-API path too by fetching `auth_client_secret` and `dns_api_token` from a secret store at first boot (mirroring the azure-vm Key Vault boot-fetch) instead of baking them into user_data — DigitalOcean has no per-droplet managed-secret store, so the likely shape is a first-boot pull from DO Spaces or an external vault.

## Teardown

The block storage volume that holds Postgres carries `prevent_destroy`, so a destroy (or any change that would replace the volume, such as a new `region`) stops at plan until you delete that line from `main.tf`. If you want to keep the data, take a snapshot or export the database first:

```sh
$EDITOR main.tf                # delete `prevent_destroy = true` on digitalocean_volume.broch_data
terraform destroy
```
