# Azure VM — Bicep template

Broch on a single Azure VM, deployed with Bicep. **This is the same template Broch, LLC runs for its own production deployment** — what you deploy here is what we run.

The VM runs the canonical [`with-postgres-external` + Caddy compose stack](../../docker-compose/with-postgres-external/) **verbatim** (cloud-init embeds it at deploy time, so the box runs the same bytes as a docker-direct deploy). You choose:

- **Database** — `databaseMode=Existing` (bring your own reachable PostgreSQL 14+ via a connection string) or `databaseMode=Managed` (the template provisions a **private** Azure Database for PostgreSQL Flexible Server — VNet-injected, no public endpoint).
- **TLS** — `certMode=Auto` (Caddy issues + auto-renews the apex + wildcard via ACME DNS-01; `dnsProvider=Cloudflare` with an API token, or `AzureDns` with the VM's managed identity — **no secret**) or `certMode=Byo` (supply your own wildcard cert + key).

**Bring your own domain.**

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

- Azure CLI logged in (`az login`), Contributor on the target resource group. **Owner or User Access Administrator** is needed only if you let the template auto-grant the Azure-DNS role (below) or set `adminObjectId` — both create role assignments.
- A database — **either** an existing **PostgreSQL 14+** reachable from the VM with a least-privilege role that owns its own database (`databaseMode=Existing`; see [Database setup](#database-setup)), **or** nothing to pre-arrange and let the template provision one (`databaseMode=Managed` — you set `postgresAdminPassword`).
- For `certMode=Auto`, DNS for your wildcard hostname on a supported provider: **Cloudflare** (API token, Zone:Read + DNS:Edit) **or** **Azure DNS** (no secret — uses the VM's managed identity). With Azure DNS, set `dnsZoneResourceGroup` and the template **grants the identity *DNS Zone Contributor* on that resource group automatically** (needs Owner/UAA there); if you only have Contributor, leave it empty and grant the role by hand. For `certMode=Byo`, a wildcard cert + key — no DNS provider needed.
- An identity provider app (Auth0, Entra ID / Azure AD, Okta, or any OIDC) — Broch has no built-in local login, so the IdP is configured at boot. Register the callback `https://<wildcardHostname>/auth/callback`. See the [identity-provider guides](https://broch.io/docs/identity-providers/).
- **No SSH key to prepare**, and with a **Managed** database no master key either. SSH is closed by default and the VM is provisioned with a generated break-glass password (`adminSshPublicKey` is an optional advanced override). With `databaseMode=Managed` you may leave `brochMasterKey` empty and the template generates one; with `databaseMode=Existing` you must supply it (the DB may already hold encrypted data). Generated secrets land in a Key Vault created in your resource group — see [Secrets & break-glass](#secrets--break-glass).
- A Broch license — activated in-app after first sign-in (Admin → License). Buy at [broch.io/pricing](https://broch.io/pricing).

## Database setup

*Only for `databaseMode=Existing`. With `databaseMode=Managed` the template provisions the private Flex Server, the `brochdb` database, and the admin role for you — skip this section.*

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
# New deploy: omit brochMasterKey — the template generates one and stores it in the
# created Key Vault. Add `brochMasterKey='<existing-key>'` ONLY when taking over a
# database that already holds Broch data. No SSH key needed (generated password).
az deployment group create \
  --resource-group broch-rg \
  --template-file main.bicep \
  --parameters main.bicepparam \
  --parameters \
      databaseConnectionString='Host=broch.postgres.database.azure.com;Database=brochdb;Username=broch;Password=<pw>;SSL Mode=Require' \
      cloudflareApiToken='<token>' \
      authClientSecret='<secret>'

# 5. Read the public IP (and where the master key was stored)
az deployment group show -g broch-rg -n main \
  --query properties.outputs.publicIpAddress.value -o tsv
az deployment group show -g broch-rg -n main \
  --query properties.outputs.masterKeySecretUri.value -o tsv
```

> **The master key is yours to keep.** `brochMasterKey` is the at-rest encryption root — Broch, LLC never sees it. With a **Managed** database you may leave it empty: the template generates one **in your subscription** and writes it to the Key Vault it creates (secret `broch-master-key`). Record it from there — you must supply the **same** value on every redeploy (a Managed redeploy left empty regenerates a *different* key, which can't decrypt the existing data). With an **Existing** database it is required: empty there yields an empty key and Broch fails to boot — never a silent wrong-key deploy. Rotating it invalidates anything DataProtection-wrapped in the database (refresh tokens, persisted license, usage blob).

## TLS — certificate & DNS

Broch serves tunnels on `*.<wildcardHostname>`, so it needs a **wildcard** cert covering the apex + `*.`. `certMode` / `dnsProvider` decide how Caddy gets it:

**`certMode=Auto` — Let's Encrypt, auto-renewing.** Caddy issues + renews the apex + wildcard via ACME DNS-01 (the only ACME challenge that issues wildcards), minting the cert against the DNS provider's API *before* any DNS points at the VM — so you validate first, cut DNS over last.

All provider modules are compiled into the broch-caddy image, so the choice is pure config:

- `dnsProvider=AzureDns` — Azure DNS via the VM's **managed identity** (no secret). Set `dnsZoneResourceGroup`; the template **grants the identity *DNS Zone Contributor* on that resource group automatically** (no manual step). The role assignment needs the deployer to have **Owner / User Access Administrator** on the zone's RG; with only Contributor, use `AzureDnsServicePrincipal` instead, or leave `dnsZoneResourceGroup` empty and grant the identity (`managedIdentityPrincipalId` is a deployment output) the role by hand. RBAC propagation is eventual — Caddy retries until it lands.
- `dnsProvider=AzureDnsServicePrincipal` — Azure DNS via a **service principal** you supply (`azureTenantId` + `azureClientId` + `azureClientSecret`), pre-granted DNS Zone Contributor on the zone. No deploy-time role assignment, so **Contributor is enough to deploy**. Also set `dnsZoneResourceGroup`.
- `dnsProvider=Cloudflare` — set `cloudflareApiToken` (Zone:Read + DNS:Edit).
- `dnsProvider=Route53` — set `awsAccessKeyId` + `awsSecretAccessKey` (Route 53 list+change rights on the zone).
- `dnsProvider=GoogleCloudDns` — set `gcpProject` + `gcpCredentialsJson` (base64 service-account key, roles/dns.admin).
- `dnsProvider=DigitalOcean` — set `doAuthToken` (DNS write scope).

**`certMode=Byo` — your own cert.** Supply `tlsCertificate` + `tlsCertificateKey` (base64 PEM covering apex + wildcard). No ACME / DNS-01 — but **renewal is yours** (replace the files, then recreate Caddy).

Watch issuance:

```sh
az vm run-command invoke -g broch-rg -n <vmName> --command-id RunShellScript \
  --scripts 'cd /opt/broch && docker compose logs --tail 50 caddy'
```

Then point DNS at the public IP, **DNS-only / grey-cloud**:

```text
A   tunnels.example.com    → <public-ip>
A   *.tunnels.example.com  → <public-ip>
```

Sign in at `https://<wildcardHostname>` — the first user holding an `AUTHENTICATION__ADMINROLES` role becomes admin.

## Secrets & break-glass

**Key Vault.** The deployment creates a Key Vault (RBAC mode) in your resource group as a durable store for the secrets it generates:

- `broch-master-key` — the at-rest encryption root (the value you supplied, or the generated one). Record this; you supply the same value on every redeploy.
- `vm-admin-password` — the generated break-glass password (only when no SSH key was supplied).

The deployment writes these via the control plane (your Contributor on the vault). To **read** them, grant yourself **Key Vault Secrets User** on the vault — or set `adminObjectId` at deploy time and the template grants it for you.

**VM access.** Inbound SSH is closed by default. The box is managed via `az vm run-command` (Azure RBAC — no SSH) and **Azure Serial Console** (sign in as `broch` with the `vm-admin-password` above). Supply `adminSshPublicKey` only if you specifically want key-based SSH (then also open `sshAllowedCidr`).

**Runtime config.** cloud-init writes `/opt/broch/.env` (mode `0600`) from the deploy parameters; the compose reads it:

- `BROCH_MASTER_KEY` → broch's at-rest encryption root
- `BROCH_DB_CONNECTION_STRING` → `ConnectionStrings__DefaultConnection` (mapped in compose)
- `AUTHENTICATION__CLIENTSECRET` → the IdP client secret
- `CLOUDFLARE_API_TOKEN` → Caddy's DNS-01 credential (Cloudflare mode)

Rotate by editing `/opt/broch/.env` and running `docker compose up -d` (a **recreate** — `env_file` is only read at container create time, so a plain `docker restart` silently keeps the old values).

> Secrets are still injected into the running container through the VM's `customData` (base64, not encrypted) — readable by anyone with VM read access. The Key Vault is the durable record of the generated secrets; wiring the compose to pull from Key Vault at runtime (instead of inline `.env`) remains a follow-up hardening item.

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
