# with-postgres-external + Caddy docker-compose

Variant of [`../with-postgres/`](../with-postgres/) that uses an **external Postgres** instead of a bundled one. You point Broch at any reachable Postgres 14+ — a managed service (DO Managed Databases, RDS, Azure Flex, CloudSQL, Neon, Supabase, …), a separately-run Postgres VM, or whatever your infrastructure already has.

Use this when:
- You need encryption-at-rest, point-in-time recovery, or automated backups — managed Postgres gives you all three out of the box.
- Your compliance posture (SOC 2, HIPAA, GDPR) forbids running an unencrypted DB on local volumes.

For the bundled-Postgres alternative (~all-in-one, simpler, less compliance-friendly), see [`../with-postgres/`](../with-postgres/).

## Architecture

```
                  ┌──────────────────────────────────────────┐
internet ──────▶  │ caddy (80/443/443udp)                    │
                  │   ↳ wildcard TLS via ACME DNS-01         │
                  └────────────────┬─────────────────────────┘
                                   │ HTTP
                  ┌────────────────▼─────────────────────────┐
                  │ broch (8080, internal only)              │
                  └────────────────┬─────────────────────────┘
                                   │ TCP:5432 (SSL recommended)
                                   ▼
                  ╔══════════════════════════════════════════╗
                  ║ Your external Postgres                   ║
                  ║   (managed DB / separate VM / cloud DB)  ║
                  ╚══════════════════════════════════════════╝
```

Only Caddy is reachable from outside. Broch reaches the external DB over the host's network — make sure firewall rules / VPC peering / connection-string SSL settings line up.

## Prerequisites

Same as [`../with-postgres/`](../with-postgres/), plus:

- An external Postgres 14+ instance reachable from this host
- A user with `CREATEDB` permission (or a pre-created database with full DDL access; Broch runs EF migrations on startup)
- A connection string in Npgsql format (see [`.env.example`](.env.example))
- The external DB's TLS settings — use `SSL Mode=VerifyFull`, which encrypts **and** authenticates the server (certificate chain + hostname). `SSL Mode=Require` only encrypts: anyone on the network path can impersonate the server and collect the credentials. If your provider signs with its own CA (RDS, DigitalOcean, Supabase, …), put its CA file in `./db-ca/` (mounted read-only into broch at `/etc/broch/db-ca`) and add `Root Certificate=/etc/broch/db-ca/<file>`. Self-managed Postgres on a network you fully trust might be on `Disable`

## Setup

```sh
# 1. Copy + fill the env template
cp .env.example .env
$EDITOR .env   # Set BROCH_MASTER_KEY, BROCH_WILDCARD_HOSTNAME, AUTHENTICATION__*,
               # CADDY_ACME_EMAIL, CLOUDFLARE_API_TOKEN, and BROCH_DB_CONNECTION_STRING.

# 2. Pull the images (broch, broch-caddy) + start
docker compose up -d

# 3. Wait for Caddy to issue certs + broch to come up
docker compose logs -f broch caddy

# 4. Verify
curl -fsS https://broch.example.com/healthz
```

If broch fails to connect to the DB at startup, the most common causes:
- Connection string typo (especially the `Host=` or password)
- TLS mismatch (`SSL Mode=VerifyFull` against a server that doesn't have TLS configured, or vice versa)
- Certificate verification failure under `VerifyFull`: the provider's CA is missing (add it to `./db-ca/` + `Root Certificate=`), or `Host=` is an IP / your own CNAME rather than the name on the server certificate
- Firewall: the DB doesn't accept connections from this host's IP
- DB doesn't exist (`Database=brochdb` but no such DB on the server)

Broch logs the actual Npgsql error on startup — `docker compose logs broch | grep -i postgres` will surface it.

## Scaling

Broch runs as a single instance and doesn't cluster: keep one `broch` replica, even against an external database. To grow, give the host more CPU and memory, or run independent stacks (for example one per region or team), each with its own database and license.

## Connection string examples

```text
DigitalOcean Managed (CA file from "Download CA certificate", saved as ./db-ca/ca-certificate.crt):
  Host=broch-db-do-user-1234.b.db.ondigitalocean.com;Port=25060;Database=brochdb;Username=broch;Password=YOUR-DB-PASSWORD;SSL Mode=VerifyFull;Root Certificate=/etc/broch/db-ca/ca-certificate.crt

AWS RDS / Aurora (CA bundle saved as ./db-ca/rds-global-bundle.pem, see below):
  Host=broch.abc123.us-east-1.rds.amazonaws.com;Port=5432;Database=brochdb;Username=broch;Password=YOUR-DB-PASSWORD;SSL Mode=VerifyFull;Root Certificate=/etc/broch/db-ca/rds-global-bundle.pem

Azure Database for PostgreSQL Flexible Server (public CA, system trust store):
  Host=broch.postgres.database.azure.com;Port=5432;Database=brochdb;Username=broch;Password=YOUR-DB-PASSWORD;SSL Mode=VerifyFull

Neon / Supabase / CloudSQL / RDS Proxy:
  Standard Npgsql format — copy from your provider's "Connection details" panel, then set
  SSL Mode=VerifyFull (plus Root Certificate= if the provider uses its own CA).
```

Fetch the Amazon RDS CA bundle (every RDS/Aurora region) into `./db-ca/`:

```sh
mkdir -p db-ca
curl -fsSL -o db-ca/rds-global-bundle.pem https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
```

The [AWS VM appliance](../../cloudformation/aws-vm/) ships this bundle for you (at `/opt/broch/db-ca/rds-global-bundle.pem` on the instance).

## Lifecycle

```sh
docker compose up -d               # Start
docker compose pull caddy && docker compose up -d   # Refresh the broch-caddy image (it tracks :latest)
docker compose logs -f broch caddy # Watch logs
docker compose down                # Stop. DB is external; no data is lost.
docker compose pull broch && docker compose up -d   # Roll forward to a new image
```

**Upgrading with Auth0:** make sure `.env` sets `AUTHENTICATION__AUDIENCE` to the Identifier of your Auth0 API before you pull a new image. Broch 1.34.0 and later refuse to start as Auth0 without it, and they check only after migrating the database, so an upgrade without it leaves you with a migrated database and a server that won't start.

## When to graduate from this example

When you'd rather run Broch on a managed container service than look after a VM and docker-compose → the Terraform modules [`../../terraform/aws-ecs/`](../../terraform/aws-ecs/) (ECS Fargate behind an Application Load Balancer) or [`../../terraform/azure-container-apps/`](../../terraform/azure-container-apps/) (Container Apps), both beta. Each provisions its own managed Postgres (RDS / Postgres Flexible Server) and keeps its secrets in Secrets Manager / Key Vault. Broch still runs as one replica there.
