# Azure VM (Bicep)

Broch on a single Azure VM running the broch + Caddy Docker Compose stack
(automatic wildcard TLS via Let's Encrypt DNS-01), connecting to an **existing
external PostgreSQL** (e.g. Azure Database for PostgreSQL Flexible Server) — the
`with-postgres-external` shape, not embedded. **Bring your own domain.**

This is the VM path for Azure, alongside the [ACA Bicep](../azure-container-apps/),
and the substrate Broch's own production is meant to dogfood.

> **⚠️ DRAFT — not validated end-to-end.** Compiles (`az bicep build`); not yet
> run on Azure. Not wired to CI; not a supported path until a run-through passes.
> Likeliest adjustments: the Ubuntu ARM image reference, VM size/quota by region,
> and SSL settings in the connection string.

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

- An Ubuntu 24.04 **ARM64** VM (default `Standard_B2ps_v2`; size availability varies
  by region/quota — this sub had `Dpsv6` quota) with your SSH key.
- A **static** Standard public IP — the address your wildcard DNS points at.
- An NSG: SSH (22) from `sshAllowedCidr`; HTTP (80) + HTTPS (443) from the internet.
- cloud-init that writes the compose stack + Caddy config, **injects the existing
  `BROCH_MASTER_KEY` and the external DB connection string**, installs Docker
  (arm64), and starts via systemd. No embedded Postgres, no data disk.

## Prerequisites

- The **existing PostgreSQL** connection string (Npgsql format, incl. `Ssl Mode=Require`).
- The **existing `BROCH_MASTER_KEY`** (paired with that database).
- A domain on **Cloudflare** + an API token (**Zone:Read + DNS:Edit**) for DNS-01.
- An **IdP app** (Auth0 / Entra / Okta / OIDC). Register the callback URL
  **`https://<wildcardHostname>/auth/callback`** before signing in.
- An Azure resource group, an SSH keypair, and the Azure CLI.

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
