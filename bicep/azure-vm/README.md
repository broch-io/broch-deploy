# Azure VM — Bicep template

Broch on a single Azure VM, deployed with Bicep. **This is the same template Broch, LLC runs for its own production deployment** — what you deploy here is what we run.

The VM runs the canonical [`with-postgres-external` + Caddy compose stack](../../docker-compose/with-postgres-external/) **verbatim** (cloud-init embeds it at deploy time, so the box runs the same bytes as a docker-direct deploy), against an **existing external PostgreSQL** (Azure Database for PostgreSQL Flexible Server, RDS, Neon, … — anything reachable). Caddy issues apex + wildcard TLS via Let's Encrypt DNS-01. **Bring your own domain.**

For the click-to-evaluate path with no VM to manage, see the [ACA Bicep](../azure-container-apps/) instead.

## What this provisions

```text
                                  ┌─────────────────────────────────────┐
internet ─ 80/443/443udp ───────▶ │ Azure VM — static public IP, NSG    │
                                  │   caddy  — wildcard TLS, ACME DNS-01 │
                                  │     ↳ HTTP ─▶ broch (8080, internal) │
                                  └──────────────────┬──────────────────┘
                                                     │ TCP:5432 (SSL)
                                                     ▼
                                  ╔═════════════════════════════════════╗
                                  ║ Your external PostgreSQL            ║
                                  ║   (Azure Flexible Server, RDS, …)   ║
                                  ╚═════════════════════════════════════╝

  The VM is stateless: broch + caddy from the canonical with-postgres-external
  compose, started by systemd. All state lives in the external DB. SSH is closed
  by default — manage via `az vm run-command` / Azure Serial Console.
```

- An Ubuntu 24.04 VM (default x86 `Standard_B2s`; ARM64 is a one-line opt-in via the `vmSize`/`imageSku` params where Ampere capacity exists).
- A **static** Standard public IP — the address your DNS points at.
- An NSG: HTTP (80) + HTTPS/HTTP-3 (443 tcp+udp) from the internet. SSH (22) is **closed by default**; set `sshAllowedCidr` to a CIDR for break-glass SSH.
- cloud-init that drops in the canonical compose + Caddyfile + Caddy.Dockerfile, writes `.env`, injects `BROCH_MASTER_KEY` + the DB connection string, installs Docker, and starts the stack via systemd. No embedded Postgres, no data disk.

Telemetry, logging, and the license are configured **in-app** (Admin → …) after first sign-in — not in the deploy.

## Prerequisites

- Azure CLI logged in (`az login`), Contributor on the target resource group.
- An external **PostgreSQL 14+** reachable from the VM, plus a **least-privilege role that owns its own database** (see [Database setup](#database-setup)). Broch runs EF migrations on startup, so the role needs full DDL on that database.
- DNS control for your wildcard hostname's parent domain, on **Cloudflare**, plus an API token (**Zone:Read + DNS:Edit**) for DNS-01. (Other providers: swap the `dns` line in the Caddyfile and the plugin in Caddy.Dockerfile.)
- An identity provider app (Auth0, Entra ID / Azure AD, Okta, or any OIDC) — Broch has no built-in local login, so the IdP is configured at boot. Register the callback `https://<wildcardHostname>/auth/callback`. See the [identity-provider guides](https://broch.io/docs/identity-providers/).
- A Broch license — activated in-app after first sign-in (Admin → License). Buy at [broch.io/pricing](https://broch.io/pricing).

## Database setup

The VM connects as a least-privilege role that owns **only its own database** — never the server admin (which would expose every database on the server). As the server admin, from a host allowed through the DB firewall:

```sql
-- connected to the default 'postgres' database:
CREATE ROLE broch LOGIN PASSWORD '<generated>';
ALTER DATABASE brochdb OWNER TO broch;

-- then connected to 'brochdb' — REQUIRED on PG15+: the database owner does NOT
-- automatically get CREATE on the public schema, so migrations otherwise fail with
-- "42501: permission denied for schema public":
ALTER SCHEMA public OWNER TO broch;
```

After the VM deploys, add its public IP (a deployment output) to the database server's firewall.

## Setup

```sh
# 1. Authenticate
az login
az account set --subscription <subscription-id>

# 2. Resource group
az group create --name broch-rg --location eastus

# 3. Fill in parameters
cp main.example.bicepparam main.bicepparam
$EDITOR main.bicepparam   # gitignored — non-secret values; pass secrets on the CLI below

# 4. Deploy (secrets via --parameters, never committed)
az deployment group create \
  --resource-group broch-rg \
  --template-file main.bicep \
  --parameters main.bicepparam \
  --parameters \
      brochMasterKey='<master-key>' \
      databaseConnectionString='Host=broch.postgres.database.azure.com;Database=brochdb;Username=broch;Password=<pw>;SSL Mode=Require' \
      cloudflareApiToken='<token>' \
      authClientSecret='<secret>'

# 5. Read the public IP
az deployment group show -g broch-rg -n main \
  --query properties.outputs.publicIpAddress.value -o tsv
```

> **The master key is yours to keep.** `brochMasterKey` is the at-rest encryption root — Broch, LLC never sees it. Generate it with `openssl rand -base64 48`, store it in your own secret store, and supply the same value on every redeploy. Rotating it invalidates anything DataProtection-wrapped in the database (refresh tokens, persisted license, usage blob). Taking over an existing Broch database? Reuse **its** master key.

## Custom domain + wildcard TLS

Broch issues tunnels on `*.<wildcardHostname>`, so Caddy mints **both** the apex and the wildcard via ACME DNS-01 (the only ACME challenge that can issue wildcards). DNS-01 issues the certs against Cloudflare's API *before* any DNS points at the VM, so you can validate first and cut DNS over last:

```sh
# Watch Caddy issue the certs (run-command, or SSH if you opened it):
az vm run-command invoke -g broch-rg -n <vmName> --command-id RunShellScript \
  --scripts 'cd /opt/broch && docker compose logs --tail 50 caddy'
```

When the certs are issued, point DNS at the public IP, **DNS-only / grey-cloud** on Cloudflare:

```text
A   tunnels.example.com    → <public-ip>
A   *.tunnels.example.com  → <public-ip>
```

Then sign in at `https://<wildcardHostname>` — the first user holding an `AUTHENTICATION__ADMINROLES` role becomes admin.

## How secrets flow at runtime

cloud-init writes `/opt/broch/.env` (mode `0600`) from your parameters; the compose reads it. There is no Key Vault — the values are injected once at deploy time:

- `BROCH_MASTER_KEY` → broch's at-rest encryption root
- `BROCH_DB_CONNECTION_STRING` → `ConnectionStrings__DefaultConnection` (mapped in compose)
- `AUTHENTICATION__CLIENTSECRET` → the IdP client secret
- `CLOUDFLARE_API_TOKEN` → Caddy's DNS-01 credential

Rotate by editing `/opt/broch/.env` and running `docker compose up -d` (a **recreate** — `env_file` is only read at container create time, so a plain `docker restart` silently keeps the old values).

> Secrets are injected through the VM's `customData` (base64, not encrypted) — readable by anyone with VM read access. For stricter posture, prefer Key Vault references / a managed identity over inline injection (a follow-up hardening item).

## Pulling a new Broch image

The documented upgrade is the same in-place flow for everyone — edit one line + recreate:

```sh
az vm run-command invoke -g broch-rg -n <vmName> --command-id RunShellScript --scripts '
  cd /opt/broch
  sed -i "s|^BROCH_VERSION=.*|BROCH_VERSION=1.27.0|" .env
  docker compose pull broch && docker compose up -d broch'
```

Caddy keeps serving across the broch restart. Broch runs EF migrations on boot, so when sharing a database across instances, keep their versions matched and roll one at a time.

## Taking over an existing database

Pointing this VM at a database another Broch instance already uses is a **migration, not a test**:

- **One instance per database.** Broch does not cluster — don't run two instances against the same DB at once. Stop the other first.
- **Version match.** A different image version migrates the schema on boot; pin `brochVersion` to the version the other instance runs.
- **Master key must match** — a fresh key cannot decrypt stored state.
- **Back up** the database + master key, and validate against a restored copy first.

## Teardown

The VM holds no state — your external database is separate and is **not** part of this deployment, so the box is disposable (back up the DB + master key, not the VM).

If you deployed into a **dedicated resource group**, teardown is one line:

```sh
az group delete --name <dedicated-rg> --yes
```

**If the VM shares a resource group with your database** (or anything else you want to keep), do **not** delete the group — it takes the DB with it. Delete only this deployment's resources (default `vmName` is `broch`):

```sh
RG=broch-rg VM=broch
az vm delete         -g $RG -n $VM --yes
az network nic delete        -g $RG -n $VM-nic
az network public-ip delete  -g $RG -n $VM-pip
az network vnet delete       -g $RG -n $VM-vnet
az network nsg delete        -g $RG -n $VM-nsg
# az vm delete leaves the OS disk — remove it too:
az disk list -g $RG --query "[?starts_with(name, '$VM')].id" -o tsv | xargs -r az disk delete --yes --ids
```
