# Azure VM (Bicep)

Broch on a single Azure VM running the broch + Caddy stack (automatic wildcard TLS via
Let's Encrypt DNS-01) against an **existing external PostgreSQL** (e.g. Azure Database for
PostgreSQL Flexible Server) — the `with-postgres-external` shape, not embedded. **Bring
your own domain.**

The VM path for Azure, alongside the [ACA Bicep](../azure-container-apps/). It deploys the
canonical [`docker-compose/with-postgres-external`](../../docker-compose/with-postgres-external/)
stack **verbatim**, so the VM runs the same thing as a docker-direct deploy.

> **`.env` changes need a recreate.** broch reads `AUTHENTICATION__*` and other settings
> from `.env` via Compose `env_file`, evaluated only at container **create** time. After
> editing `/opt/broch/.env`, run `docker compose up -d` (recreate) — a plain
> `docker restart` reuses the old environment and silently ignores the change.

## What it provisions

- An Ubuntu 24.04 VM (default x86 `Standard_B2s`; ARM64 is a one-line opt-in via the
  `vmSize`/`imageSku` params where Ampere capacity exists).
- A **static** Standard public IP — the address your DNS points at.
- An NSG: HTTP (80) + HTTPS (443) from the internet. SSH (22) is **closed by default** —
  set `sshAllowedCidr` to a CIDR for break-glass SSH; otherwise manage via
  `az vm run-command` / Azure Serial Console.
- cloud-init that deploys the canonical compose + Caddyfile + Caddy.Dockerfile verbatim,
  writes a templated `.env`, **injects `BROCH_MASTER_KEY` + the DB connection string**,
  installs Docker, and starts via systemd. No embedded Postgres, no data disk.
- **Telemetry, logging, and the license are configured in-app** (Admin UI) after first
  sign-in — not baked into the deploy.

## Prerequisites

- An external PostgreSQL database + a **least-privilege role** that owns it (see *Database
  setup*). Generate a strong `BROCH_MASTER_KEY` (`openssl rand -base64 48`); if you're
  taking over a database an existing Broch instance already uses, reuse **its** master key
  (see *Taking over an existing database*).
- A domain on **Cloudflare** + an API token (**Zone:Read + DNS:Edit**) for DNS-01. (Other
  DNS providers: swap the `dns` line in the Caddyfile and the plugin in Caddy.Dockerfile.)
- An **IdP app** (Auth0 / Entra / Okta / OIDC). Register the callback
  **`https://<wildcardHostname>/auth/callback`**.
- An Azure resource group, an SSH keypair, and the Azure CLI.

## Database setup (run once)

The VM connects as a **least-privilege role that owns only its own database** — never the
server admin (which would hand the VM access to every database on the server). As the
server admin, from a host allowed through the DB firewall:

```sql
-- connected to the default 'postgres' database:
CREATE ROLE broch LOGIN PASSWORD '<generated>';
ALTER DATABASE brochdb OWNER TO broch;

-- then connected to 'brochdb' — REQUIRED on PG15+: the database owner does NOT
-- automatically get CREATE on the public schema, so migrations otherwise fail with
-- "42501: permission denied for schema public":
ALTER SCHEMA public OWNER TO broch;
```

Use that role + password in `databaseConnectionString`, and **pin `brochVersion`** (don't
rely on `latest`).

## Deploy

```bash
cp main.example.bicepparam main.bicepparam   # fill in non-secret values
$EDITOR main.bicepparam

az deployment group create \
  -g <your-resource-group> \
  --template-file main.bicep \
  --parameters main.bicepparam \
  --parameters \
      brochMasterKey='<master-key>' \
      databaseConnectionString='Host=<db-host>;Database=<db>;Username=<user>;Password=<pw>;SSL Mode=Require' \
      cloudflareApiToken='<token>' \
      authClientSecret='<secret>'

az deployment group show -g <your-resource-group> -n main \
  --query properties.outputs.publicIpAddress.value -o tsv
```

Pass `brochMasterKey`, `databaseConnectionString`, `cloudflareApiToken`, and
`authClientSecret` on the CLI (or via Key Vault references) — never commit them.

## After deploy

1. **Firewall** — add the output IP to your database server's firewall.
2. **TLS** — Caddy builds its image and mints the apex + wildcard certs via DNS-01 (this
   works *before* DNS points at the VM). Watch it via `az vm run-command` (or SSH, if
   enabled): `cd /opt/broch && docker compose logs -f caddy`.
3. **DNS** — point `wildcardHostname` (apex + `*`) at the output IP, **DNS-only /
   grey-cloud** on Cloudflare. DNS-01 issues the cert before this, so validate the cert
   first and switch DNS last.
4. Sign in at `https://<wildcardHostname>` — the first user holding an
   `AUTHENTICATION__ADMINROLES` role becomes admin. Activate your license under
   **Admin → License**.

## Taking over an existing database

Pointing this VM at a database another Broch instance already uses is a **migration, not a
test**:

- **One instance per database.** Broch does not cluster — do not run two instances against
  the same DB at once. Stop the other instance first.
- **Version match.** Broch runs EF migrations on boot; a different image version migrates
  the schema. Pin `brochVersion` to the version the other instance runs.
- **Master key must match** — a fresh key cannot decrypt stored state (Data Protection
  keyring, IdP tokens, license).
- **Back up** the database + master key, and validate against a restored copy first.

## Notes

- **State lives in the external database**, not the VM — the VM is stateless (recreate it
  freely; back up the DB + master key).
- **Upgrades:** bump `BROCH_VERSION` in `/opt/broch/.env` (pinned), then
  `docker compose pull && docker compose up -d`.
- Secrets are injected into the VM's `customData` (base64) — visible to anyone with VM
  read access. For production, prefer Key Vault references / a managed identity over inline
  injection (a follow-up hardening item).
