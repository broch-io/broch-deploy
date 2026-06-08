# with-postgres-external + Caddy docker-compose

Variant of [`../with-postgres/`](../with-postgres/) that uses an **external Postgres** instead of a bundled one. You point Broch at any reachable Postgres 14+ — a managed service (DO Managed Databases, RDS, Azure Flex, CloudSQL, Neon, Supabase, …), a separately-run Postgres VM, or whatever your infrastructure already has.

Use this when:
- You need encryption-at-rest, point-in-time recovery, or automated backups — managed Postgres gives you all three out of the box.
- You need horizontal scaling. Multi-replica Broch requires a shared external database — multiple Broch containers can't coordinate against an embedded sidecar.
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
- The external DB's TLS settings — most managed providers require `SSL Mode=Require`; self-managed Postgres might be on `Disable` for an internal VPC

## Setup

```sh
# 1. Copy + fill the env template
cp .env.example .env
$EDITOR .env   # Set BROCH_MASTER_KEY, BROCH_WILDCARD_HOSTNAME, AUTHENTICATION__*,
               # CADDY_ACME_EMAIL, CLOUDFLARE_API_TOKEN, and BROCH_DB_CONNECTION_STRING.

# 2. Start
docker compose up -d --build

# 3. Wait for Caddy to issue certs + broch to come up
docker compose logs -f broch caddy

# 4. Verify
curl -fsS https://tunnels.example.com/healthz
```

If broch fails to connect to the DB at startup, the most common causes:
- Connection string typo (especially the `Host=` or password)
- TLS mismatch (`SSL Mode=Require` against a server that doesn't have TLS configured, or vice versa)
- Firewall: the DB doesn't accept connections from this host's IP
- DB doesn't exist (`Database=brochdb` but no such DB on the server)

Broch logs the actual Npgsql error on startup — `docker compose logs broch | grep -i postgres` will surface it.

## Horizontal scaling

This shape is what you need for multi-replica. To run two or more Broch containers:

1. Scale up: `docker compose up -d --scale broch=2` (or duplicate the service block with a different name + port mapping)
2. The Caddyfile's `reverse_proxy broch:8080` needs to be updated to load-balance across the replicas — `reverse_proxy broch-1:8080 broch-2:8080` with `lb_policy round_robin`
3. Tunnel state lives in-memory per-replica, so the load balancer needs **sticky sessions** or **consistent-hash routing on tunnel hostname** to ensure a tunnel's owner replica always handles its traffic
4. Caddy supports `lb_policy ip_hash` for sticky-by-IP, but for tunnel WebSockets you want sticky-by-hostname — see the Caddy `header` matcher docs

If you go down this path, also consider moving Caddy to a separate node (or a managed LB like Cloudflare Spectrum / DO Load Balancer) so it isn't a single point of failure.

## Connection string examples

```text
DigitalOcean Managed:
  Host=broch-db-do-user-1234.b.db.ondigitalocean.com;Port=25060;Database=brochdb;Username=broch;Password=YOUR-DB-PASSWORD;SSL Mode=Require

AWS RDS:
  Host=broch.abc123.us-east-1.rds.amazonaws.com;Port=5432;Database=brochdb;Username=broch;Password=YOUR-DB-PASSWORD;SSL Mode=Require

Azure Database for PostgreSQL Flexible Server:
  Host=broch.postgres.database.azure.com;Port=5432;Database=brochdb;Username=broch;Password=YOUR-DB-PASSWORD;SSL Mode=Require

Neon / Supabase / CloudSQL / RDS Proxy:
  Standard Npgsql format — copy from your provider's "Connection details" panel.
```

## Lifecycle

```sh
docker compose up -d --build       # Start (rebuilds Caddy if Dockerfile changed)
docker compose logs -f broch caddy # Watch logs
docker compose down                # Stop. DB is external; no data is lost.
docker compose pull broch && docker compose up -d   # Roll forward to a new image
```

## When to graduate from this example

When you want a fully cloud-managed control plane (no docker-compose, no Droplet/VM management) → [`../../terraform/aws-ecs/`](../../terraform/aws-ecs/) or [`../../terraform/azure-container-apps/`](../../terraform/azure-container-apps/). Both already provision their own external Postgres (RDS / Postgres Flexible Server) and a load balancer.
