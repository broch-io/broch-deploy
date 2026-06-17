# Azure VM (Bicep)

Broch on a single Azure VM running the broch + Caddy Docker Compose stack
(automatic wildcard TLS via Let's Encrypt DNS-01), connecting to an **existing
external PostgreSQL** (e.g. Azure Database for PostgreSQL Flexible Server) — the
`with-postgres-external` shape, not embedded. **Bring your own domain.**

This is the VM path for Azure, alongside the [ACA Bicep](../azure-container-apps/),
and the substrate Broch's own production is meant to dogfood.

> **⚠️ DRAFT — partially validated (2026-06-17).** Deployed on Azure (x86
> `Standard_B2s`, eastus): the VM provisioned, cloud-init installed Docker + built the
> custom Caddy, **broch booted against a fresh `brochvm` database and migrated**, and
> **Caddy obtained real apex + `*.` wildcard certs via DNS-01**. **Still unvalidated:**
> SSO sign-in (needs an IdP app + the VM's callback URL registered + DNS pointing at the
> VM) and the prod-DB cutover. Not yet wired to CI.

> **🚨 PRODUCTION CUTOVER — read before pointing this at a live database.**
> Connecting this VM to an existing Broch database is a **migration, not a test**:
> - **One instance per database.** Broch does not cluster — do **not** run this VM
>   against the live DB while the current instance (ACA) is also connected. Stop the
>   old instance first (maintenance window).
> - **Version match.** Broch runs EF migrations on boot. Booting a different image
>   version against the live DB migrates the prod schema — pin `brochVersion` to the
>   currently-running version.
> - **Master key must match.** `brochMasterKey` MUST be the existing key the DB was
>   encrypted with; a fresh key cannot decrypt stored state.
> - **Back up first** (`broch-postgres` + the master key) and have a rollback.
> - Validate the template against a **restored copy** of the DB before the real cutover.

## What it provisions

- An Ubuntu 24.04 VM (default **x86** `Standard_B2s`; ARM64 is a one-line opt-in via
  `vmSize` + `imageSku` where Ampere capacity exists) with your SSH key.
- A **static** Standard public IP — the address your wildcard DNS points at.
- An NSG: SSH (22) from `sshAllowedCidr`; HTTP (80) + HTTPS (443) from the internet.
- cloud-init that writes the compose stack + Caddy config, **injects `BROCH_MASTER_KEY`
  and the external DB connection string**, installs Docker, and starts via systemd.
  No embedded Postgres, no data disk.
- **Note:** the database server's firewall must allow the VM's public IP (the output
  address) — add a rule after deploy.

## Prerequisites

- A PostgreSQL database + a **least-privilege role** for it (see *Database setup* below).
  For a **new** database, generate a fresh `BROCH_MASTER_KEY`; to take over an
  **existing** one, reuse its master key (cutover warning above).
- A domain on **Cloudflare** + an API token (**Zone:Read + DNS:Edit**) for DNS-01.
- An **IdP app** (Auth0 / Entra / Okta / OIDC). Register the callback URL
  **`https://<wildcardHostname>/auth/callback`** before signing in.
- An Azure resource group, an SSH keypair, and the Azure CLI.

## Database setup (run once)

The VM connects as a **least-privilege role that owns only its own database** — never
the server admin (which would hand the VM access to every database on the server). As
the server admin, from a host allowed through the DB firewall:

```sql
-- connected to the default 'postgres' database:
CREATE ROLE broch_vm LOGIN PASSWORD '<generated>';
ALTER DATABASE brochvm OWNER TO broch_vm;

-- then connected to 'brochvm' — REQUIRED on PG15+: the database owner does NOT
-- automatically get CREATE on the public schema, so migrations otherwise fail with
-- "42501: permission denied for schema public":
ALTER SCHEMA public OWNER TO broch_vm;
```

Use `broch_vm` + that password in `databaseConnectionString`, and **pin `brochVersion`**
(don't rely on `latest`).

## Deploy (local-first, by hand)

```bash
cp main.example.bicepparam main.bicepparam   # fill in non-secret values
$EDITOR main.bicepparam

az deployment group create \
  -g broch-rg \
  --template-file main.bicep \
  --parameters main.bicepparam \
  --parameters \
      brochMasterKey='<existing-master-key>' \
      databaseConnectionString='Host=broch-postgres.postgres.database.azure.com;Database=brochdb;Username=<user>;Password=<pw>;Ssl Mode=Require' \
      cloudflareApiToken='<token>' \
      authClientSecret='<secret>'

az deployment group show -g broch-rg -n main \
  --query properties.outputs.publicIpAddress.value -o tsv
```

Pass `brochMasterKey`, `databaseConnectionString`, `cloudflareApiToken`, and
`authClientSecret` on the CLI (or via Key Vault references) — never commit them.

## After deploy

1. **TLS** — Caddy builds the custom image and provisions the apex + wildcard certs
   via DNS-01. `ssh` in, `cd /opt/broch && docker compose logs -f caddy`.
2. **DNS cutover** — when ready, point `wildcardHostname` (apex + `*`) at the output
   IP, **DNS-only / grey-cloud** on Cloudflare. (DNS-01 issues the cert *before* this,
   so you can validate the cert first and switch DNS last.)
3. Sign in at `https://<wildcardHostname>`.

## Notes

- **State lives in the external database**, not on the VM — the VM is stateless
  (recreate it freely; back up the DB + master key).
- **Upgrades:** `ssh` in, bump `BROCH_VERSION` in `/opt/broch/.env` (pin it),
  `docker compose pull && docker compose up -d`. Mind the version/migration note above.
- Secrets are injected into the VM's `customData` (base64) — visible to anyone with
  VM read access. For production, prefer Key Vault references / a managed identity
  over inline injection (a follow-up hardening item).
